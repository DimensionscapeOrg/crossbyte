package crossbyte.db.mongodb._internal;

import crossbyte.db.mongodb.bson.BsonBinary;
import crossbyte.db.mongodb.bson.BsonDateTime;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.BsonDouble;
import crossbyte.db.mongodb.bson.BsonInt64;
import crossbyte.db.mongodb.bson.BsonJavaScript;
import crossbyte.db.mongodb.bson.BsonRegex;
import crossbyte.db.mongodb.bson.BsonTimestamp;
import crossbyte.db.mongodb.bson.Decimal128;
import crossbyte.db.mongodb.bson.MaxKey;
import crossbyte.db.mongodb.bson.MinKey;
import crossbyte.db.mongodb.bson.ObjectId;
import crossbyte.errors.ArgumentError;
import haxe.Int64;
import haxe.io.Bytes;

/**
	Encodes BSON into one growable buffer, straight from the values given.

	A connection keeps one and resets it for every message, so encoding a
	command allocates nothing once the buffer has grown to the largest
	message sent; a document's length is written as a placeholder and filled
	in when its end is reached, rather than by encoding it separately first.
**/
class BsonWriter {
	/** How deeply documents and arrays may nest; a cycle stops here rather than overflowing the stack. **/
	public static inline var MAX_DEPTH:Int = 200;

	public var buffer(default, null):Bytes;
	public var length(default, null):Int = 0;

	public function new(capacity:Int = 1024) {
		buffer = Bytes.alloc(capacity < 64 ? 64 : capacity);
	}

	public inline function reset():Void {
		length = 0;
	}

	/** The bytes written so far, as a new `Bytes`. **/
	public function toBytes():Bytes {
		return buffer.sub(0, length);
	}

	public inline function ensure(extra:Int):Void {
		if (length + extra > buffer.length) {
			__grow(length + extra);
		}
	}

	public inline function byte(value:Int):Void {
		ensure(1);
		buffer.set(length++, value);
	}

	public inline function int32(value:Int):Void {
		ensure(4);
		buffer.setInt32(length, value);
		length += 4;
	}

	public inline function int64(value:Int64):Void {
		ensure(8);
		buffer.setInt32(length, value.low);
		buffer.setInt32(length + 4, value.high);
		length += 8;
	}

	public inline function double(value:Float):Void {
		ensure(8);
		buffer.setDouble(length, value);
		length += 8;
	}

	public inline function patchInt32(at:Int, value:Int):Void {
		buffer.setInt32(at, value);
	}

	public function blit(source:Bytes, position:Int, count:Int):Void {
		ensure(count);
		buffer.blit(length, source, position, count);
		length += count;
	}

	/** A C string: the text as UTF-8 and a NUL. A NUL inside it would end it early, so it is refused. **/
	public function cstring(text:String):Void {
		if (__utf8(text, true) < 0) {
			var shown:String = StringTools.replace(text, String.fromCharCode(0), "\\0");
			throw new ArgumentError('A BSON field name cannot contain a NUL character: "$shown".');
		}

		byte(0);
	}

	/** A BSON string: its length with the NUL, the text as UTF-8, and the NUL. **/
	public function string(text:String):Void {
		var at:Int = length;
		int32(0);
		var count:Int = __utf8(text, false);
		byte(0);
		patchInt32(at, count + 1);
	}

	/** Starts a document, and answers where, for `endDocument`. **/
	public inline function beginDocument():Int {
		var at:Int = length;
		int32(0);
		return at;
	}

	public inline function endDocument(at:Int):Void {
		byte(0);
		patchInt32(at, length - at);
	}

	/**
		Writes `value` as a whole document: a `BsonDocument` in its own order,
		a `StringMap`, or an anonymous object.
	**/
	public function document(value:Dynamic, depth:Int = 0):Void {
		if (depth > MAX_DEPTH) {
			throw new ArgumentError('A document nests more than $MAX_DEPTH levels deep, or refers to itself.');
		}

		var at:Int = beginDocument();
		fields(value, depth);
		endDocument(at);
	}

	/**
		Writes the fields of `value` into a document already begun: how a
		command's own fields and a caller's are put in one document.
	**/
	public function fields(value:Dynamic, depth:Int = 0):Void {
		if (value == null) {
			return;
		}

		if (isPlainObject(value)) {
			__anonymousFields(value, depth);
			return;
		}

		if (Std.isOfType(value, BsonDocument)) {
			var document:BsonDocument = value;

			for (i in 0...document.length) {
				this.value(document.keyAt(i), document.valueAt(i), depth + 1);
			}

			return;
		}

		if (Std.isOfType(value, haxe.ds.StringMap)) {
			var map:haxe.ds.StringMap<Dynamic> = value;

			for (key in map.keys()) {
				this.value(key, map.get(key), depth + 1);
			}

			return;
		}

		throw new ArgumentError('${__describe(value)} is not a document; use an anonymous object, a BsonDocument or a StringMap.');
	}

	/**
		Writes the document `value` for an insert, with `_id` first. Answers
		the `_id`: the one it had, or a new `ObjectId` written in front when it
		had none.
	**/
	public function documentWithId(value:Dynamic):Dynamic {
		var at:Int = beginDocument();
		var id:Dynamic = null;

		if (isPlainObject(value)) {
			id = Reflect.field(value, "_id");

			if (id == null) {
				id = new ObjectId();
			}

			this.value("_id", id, 1);

			for (name in Reflect.fields(value)) {
				if (name != "_id") {
					this.value(name, Reflect.field(value, name), 1);
				}
			}
		} else if (Std.isOfType(value, BsonDocument)) {
			var document:BsonDocument = value;
			id = document.get("_id");

			if (id == null || !document.exists("_id")) {
				id = new ObjectId();
				this.value("_id", id, 1);

				for (i in 0...document.length) {
					if (document.keyAt(i) != "_id") {
						this.value(document.keyAt(i), document.valueAt(i), 1);
					}
				}
			} else {
				fields(document, 0);
			}
		} else if (Std.isOfType(value, haxe.ds.StringMap)) {
			var map:haxe.ds.StringMap<Dynamic> = value;
			id = map.get("_id");

			if (id == null) {
				id = new ObjectId();
			}

			this.value("_id", id, 1);

			for (key in map.keys()) {
				if (key != "_id") {
					this.value(key, map.get(key), 1);
				}
			}
		} else {
			throw new ArgumentError('${__describe(value)} is not a document; use an anonymous object, a BsonDocument or a StringMap.');
		}

		endDocument(at);
		return id;
	}

	/** An array, as BSON writes one: a document keyed "0", "1", ... **/
	public function array(items:Array<Dynamic>, depth:Int):Void {
		if (depth > MAX_DEPTH) {
			throw new ArgumentError('A document nests more than $MAX_DEPTH levels deep, or refers to itself.');
		}

		var at:Int = beginDocument();

		for (i in 0...items.length) {
			__element(i, items[i], depth + 1);
		}

		endDocument(at);
	}

	/**
		One field: its type byte, its name and its value.

		Which BSON type a value becomes is decided in this order: `null`; a
		`String`; a `Bool`; a `haxe.Int64`, as int64 (tested before `Int`,
		since on cpp and the jvm an Int64 held in a `Dynamic` also passes
		`Std.isOfType(v, Int)`); a whole number in the 32-bit range, as int32;
		any other number, as a double; then the BSON types by class; and last,
		an anonymous object or `StringMap` as a document. Anything else (an
		instance of some other class, an enum, a function) is refused rather
		than guessed at.

		The value's kind is asked once (`__kindOf`), and only an instance of a
		class goes on to the BSON classes, the common ones first, rather than
		a chain of `Std.isOfType` per value: up to six for a number and
		seventeen for a nested object, a fifth to a third of encoding a
		document on hxcpp.
	**/
	public function value(name:String, value:Dynamic, depth:Int):Void {
		switch (__kindOf(value)) {
			case KIND_NULL:
				byte(0x0A);
				cstring(name);
			case KIND_STRING:
				byte(0x02);
				cstring(name);
				string(value);
			case KIND_BOOL:
				byte(0x08);
				cstring(name);
				byte(value ? 1 : 0);
			case KIND_INT:
				byte(0x10);
				cstring(name);
				#if cpp
				int32(value);
				#else
				// Std.int, not an implicit conversion: off hxcpp an integral
				// Float is of this kind, and the interpreter would carry it
				// into setInt32 still a float.
				int32(Std.int(value));
				#end
			case KIND_FLOAT:
				var number:Float = value;

				if (__wholeInt32(number)) {
					byte(0x10);
					cstring(name);
					int32(Std.int(number));
				} else {
					byte(0x01);
					cstring(name);
					double(number);
				}
			case KIND_INT64:
				byte(0x12);
				cstring(name);
				int64(value);
			case KIND_ARRAY:
				byte(0x04);
				cstring(name);
				array(value, depth);
			case KIND_OBJECT:
				byte(0x03);
				cstring(name);
				__anonymous(value, depth);
			default:
				__rest(name, value, depth);
		}
	}

	/** A field that is an int64 whatever its value: a cursor id, a transaction number. **/
	public function int64Field(name:String, value:Int64):Void {
		byte(0x12);
		cstring(name);
		int64(value);
	}

	// Fields whose type the caller knows (a driver's own: a collection's
	// name, a batch size, a flag), written without asking `value` what they
	// are, and without boxing them to ask.

	/** A string field; `null` is written as BSON null, as `value` would. **/
	public function stringField(name:String, text:String):Void {
		if (text == null) {
			byte(0x0A);
			cstring(name);
			return;
		}

		byte(0x02);
		cstring(name);
		string(text);
	}

	public function int32Field(name:String, value:Int):Void {
		byte(0x10);
		cstring(name);
		int32(value);
	}

	public function boolField(name:String, value:Bool):Void {
		byte(0x08);
		cstring(name);
		byte(value ? 1 : 0);
	}

	/** Starts a sub-document field, and answers where, for `endDocument`. **/
	public function beginDocumentField(name:String):Int {
		byte(0x03);
		cstring(name);
		return beginDocument();
	}

	/** Starts an array field, whose elements are named by `elementName`; answers where, for `endDocument`. **/
	public function beginArrayField(name:String):Int {
		byte(0x04);
		cstring(name);
		return beginDocument();
	}

	/** The name of an array's element `index`: its index, as text. **/
	public static inline function elementName(index:Int):String {
		return index < __INDEX_NAMES.length ? __INDEX_NAMES[index] : Std.string(index);
	}

	/**
		Whether `value`, held in a `Dynamic`, is a `haxe.Int64`.

		Not `Int64.isInt64` alone. On hxcpp that answers true for every `Int`,
		since its boxed Int64 converts from one, and an int32 field would go
		out as an int64; the box's own type code says which it is. Even that
		cannot see an Int64 from -1 to 255, which hxcpp boxes as the shared
		`Int` of the same value; see `BsonInt64`.
	**/
	public static inline function isInt64(value:Dynamic):Bool {
		#if cpp
		return value != null && (untyped __cpp__("{0}->__GetType() == vtInt64", value) : Bool);
		#else
		return Int64.isInt64(value);
		#end
	}

	/**
		Whether `value` is an anonymous object, as opposed to an instance of a
		class or anything else `Reflect` can see into.
	**/
	public static #if cpp inline #end function isPlainObject(value:Dynamic):Bool {
		#if cpp
		// What Type.getClass and Type.typeof ask between them, without the
		// class name each compares as text.
		return value != null && (untyped __cpp__("{0}->__GetType() == vtObject", value) : Bool);
		#else
		if (value == null || Type.getClass(value) != null) {
			return false;
		}

		return switch (Type.typeof(value)) {
			case TObject: true;
			default: false;
		}
		#end
	}

	// What __kindOf answers: hxcpp's own codes, as `__GetType()` gives them.
	@:noCompletion private static inline var KIND_NULL:Int = 0;
	@:noCompletion private static inline var KIND_FLOAT:Int = 1;
	@:noCompletion private static inline var KIND_BOOL:Int = 2;
	@:noCompletion private static inline var KIND_STRING:Int = 3;
	@:noCompletion private static inline var KIND_OBJECT:Int = 4;
	@:noCompletion private static inline var KIND_ARRAY:Int = 5;
	@:noCompletion private static inline var KIND_CLASS:Int = 8;
	@:noCompletion private static inline var KIND_INT64:Int = 9;
	@:noCompletion private static inline var KIND_INT:Int = 0xFF;
	@:noCompletion private static inline var KIND_OTHER:Int = -1;

	/**
		What kind of value `value` is, asked once: null, a string, a bool, an
		int, a float, an int64, an array, an anonymous object, or something
		else (a class instance, and on hxcpp also a function or an enum),
		which `__rest` sorts out.

		On hxcpp it is the value's own type code, one virtual call. Elsewhere
		the order of tests a primitive needs (an Int64 before an Int, since
		on the jvm a small one passes as an Int), and then one
		and then one `Type.getClass` for anything else. Not `Type.typeof`
		throughout: it makes a `TClass` for every class instance, a string
		included, on most targets.

		On hxcpp a whole number held as a `Float` comes back a float, where
		`Std.isOfType(v, Int)` would say int: the `KIND_FLOAT` branch asks
		`__wholeInt32` for that, and nowhere else does it need to.
	**/
	@:noCompletion private static inline function __kindOf(value:Dynamic):Int {
		#if cpp
		return value == null ? KIND_NULL : (untyped __cpp__("{0}->__GetType()", value) : Int);
		#else
		return if (value == null) {
			KIND_NULL;
		} else if (Std.isOfType(value, String)) {
			KIND_STRING;
		} else if (Std.isOfType(value, Bool)) {
			KIND_BOOL;
		} else if (isInt64(value)) {
			KIND_INT64;
		} else if (Std.isOfType(value, Int)) {
			KIND_INT;
		} else if (Std.isOfType(value, Float)) {
			KIND_FLOAT;
		} else if (Std.isOfType(value, Array)) {
			KIND_ARRAY;
		} else if (Type.getClass(value) != null) {
			KIND_CLASS;
		} else {
			// isPlainObject's question, its class half answered already.
			switch (Type.typeof(value)) {
				case TObject: KIND_OBJECT;
				default: KIND_OTHER;
			}
		}
		#end
	}

	/**
		Whether a value of kind `KIND_FLOAT` is a whole number in the 32-bit
		range, written as an int32 as `Std.isOfType(v, Int)` would have it.
		Only on hxcpp can one be: everywhere else `__kindOf` has said int for
		it already.
	**/
	@:noCompletion private static inline function __wholeInt32(number:Float):Bool {
		#if cpp
		// The range first: casting a double outside it to an int is undefined.
		return number >= -2147483648.0 && number <= 2147483647.0 && Std.int(number) == number;
		#else
		return false;
		#end
	}

	/** An anonymous object as a document: `document`, without asking again what it is. **/
	@:noCompletion private function __anonymous(value:Dynamic, depth:Int):Void {
		if (depth > MAX_DEPTH) {
			throw new ArgumentError('A document nests more than $MAX_DEPTH levels deep, or refers to itself.');
		}

		var at:Int = beginDocument();
		__anonymousFields(value, depth);
		endDocument(at);
	}

	@:noCompletion private inline function __anonymousFields(value:Dynamic, depth:Int):Void {
		for (name in Reflect.fields(value)) {
			this.value(name, Reflect.field(value, name), depth + 1);
		}
	}

	/**
		A value that is none of the kinds `value` writes directly: an instance
		of one of the BSON classes, the ones values most often are first, or
		else nothing BSON can hold.
	**/
	@:noCompletion private function __rest(name:String, value:Dynamic, depth:Int):Void {
		if (Std.isOfType(value, ObjectId)) {
			byte(0x07);
			cstring(name);
			blit((value : ObjectId).bytes, 0, 12);
			return;
		}

		if (Std.isOfType(value, Date)) {
			byte(0x09);
			cstring(name);
			int64(Int64.fromFloat(Math.ffloor((value : Date).getTime())));
			return;
		}

		if (Std.isOfType(value, BsonDocument) || Std.isOfType(value, haxe.ds.StringMap)) {
			byte(0x03);
			cstring(name);
			document(value, depth);
			return;
		}

		if (Std.isOfType(value, BsonDateTime)) {
			byte(0x09);
			cstring(name);
			int64((value : BsonDateTime).millis);
			return;
		}

		if (Std.isOfType(value, Bytes)) {
			var data:Bytes = value;
			byte(0x05);
			cstring(name);
			int32(data.length);
			byte(0);
			blit(data, 0, data.length);
			return;
		}

		if (Std.isOfType(value, BsonBinary)) {
			var binary:BsonBinary = value;
			byte(0x05);
			cstring(name);

			if (binary.subtype == BsonBinary.BINARY_OLD) {
				// The old subtype repeats the length inside the data.
				int32(binary.data.length + 4);
				byte(binary.subtype);
				int32(binary.data.length);
			} else {
				int32(binary.data.length);
				byte(binary.subtype);
			}

			blit(binary.data, 0, binary.data.length);
			return;
		}

		if (Std.isOfType(value, Decimal128)) {
			byte(0x13);
			cstring(name);
			blit((value : Decimal128).bytes, 0, 16);
			return;
		}

		if (Std.isOfType(value, BsonDouble)) {
			byte(0x01);
			cstring(name);
			double((value : BsonDouble).value);
			return;
		}

		if (Std.isOfType(value, BsonInt64)) {
			int64Field(name, (value : BsonInt64).value);
			return;
		}

		if (Std.isOfType(value, BsonTimestamp)) {
			var timestamp:BsonTimestamp = value;
			byte(0x11);
			cstring(name);
			int32(timestamp.increment);
			int32(timestamp.time);
			return;
		}

		if (Std.isOfType(value, BsonRegex)) {
			var regex:BsonRegex = value;
			byte(0x0B);
			cstring(name);
			cstring(regex.pattern);
			cstring(regex.options);
			return;
		}

		if (Std.isOfType(value, MinKey)) {
			byte(0xFF);
			cstring(name);
			return;
		}

		if (Std.isOfType(value, MaxKey)) {
			byte(0x7F);
			cstring(name);
			return;
		}

		if (Std.isOfType(value, BsonJavaScript)) {
			var code:BsonJavaScript = value;

			if (code.scope == null) {
				byte(0x0D);
				cstring(name);
				string(code.code);
			} else {
				byte(0x0F);
				cstring(name);
				var at:Int = length;
				int32(0);
				string(code.code);
				document(code.scope, depth);
				patchInt32(at, length - at);
			}

			return;
		}

		throw new ArgumentError('Field "$name" holds ${__describe(value)}, which has no BSON form. Use an anonymous object for a document.');
	}

	/**
		An array element, whose name is its index. The names of the first
		1024 are made once, so an ordinary array costs no string per element.
	**/
	@:noCompletion private inline function __element(index:Int, value:Dynamic, depth:Int):Void {
		this.value(elementName(index), value, depth);
	}

	// Filled when the class initialises, before any thread can use it, and
	// only read afterwards.
	@:noCompletion private static final __INDEX_NAMES:Array<String> = [for (i in 0...1024) Std.string(i)];

	/**
		Writes `text` as UTF-8, and answers how many bytes it took, or -1 as
		soon as it meets a NUL, when `refuseNul` asks for that.

		Directly from the character codes rather than through
		`Bytes.ofString`, which would make a new buffer for every string. What
		a code is depends on the target: a UTF-16 unit on cpp, the jvm, hl and
		JavaScript, whose surrogate pairs are joined here; a whole code point
		on the interpreter; and on neko, which has no Unicode strings, a byte
		already in UTF-8, copied as it is.
	**/
	@:noCompletion private function __utf8(text:String, refuseNul:Bool):Int {
		var count:Int = text.length;
		#if !target.unicode
		ensure(count);

		for (i in 0...count) {
			var b:Int = StringTools.fastCodeAt(text, i);

			if (b == 0 && refuseNul) {
				return -1;
			}

			buffer.set(length++, b);
		}

		return count;
		#else
		// Room for the worst case, so the loop need not check: three bytes a
		// UTF-16 unit, since a code point above U+FFFF takes two units for its
		// four bytes; but on the interpreter one code is a whole code point,
		// and can take four.
		ensure(count * #if eval 4 #else 3 #end);
		var start:Int = length;
		var out:Bytes = buffer;
		var at:Int = length;
		var i:Int = 0;

		while (i < count) {
			var c:Int = StringTools.fastCodeAt(text, i++);

			if (c < 0x80) {
				if (c == 0 && refuseNul) {
					length = at;
					return -1;
				}

				out.set(at++, c);
			} else if (c < 0x800) {
				out.set(at++, 0xC0 | (c >> 6));
				out.set(at++, 0x80 | (c & 0x3F));
			} else {
				if (c >= 0xD800 && c <= 0xDFFF) {
					var low:Int = i < count ? StringTools.fastCodeAt(text, i) : 0;

					if (c <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF) {
						c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
						i++;
					} else {
						// A lone surrogate has no UTF-8 form, and the server
						// refuses invalid UTF-8; it becomes the replacement
						// character, as the jvm and JavaScript encoders do.
						c = 0xFFFD;
					}
				}

				if (c < 0x10000) {
					out.set(at++, 0xE0 | (c >> 12));
					out.set(at++, 0x80 | ((c >> 6) & 0x3F));
					out.set(at++, 0x80 | (c & 0x3F));
				} else {
					out.set(at++, 0xF0 | (c >> 18));
					out.set(at++, 0x80 | ((c >> 12) & 0x3F));
					out.set(at++, 0x80 | ((c >> 6) & 0x3F));
					out.set(at++, 0x80 | (c & 0x3F));
				}
			}
		}

		length = at;
		return at - start;
		#end
	}

	@:noCompletion private function __grow(required:Int):Void {
		var capacity:Int = buffer.length * 2;

		while (capacity < required) {
			capacity *= 2;
		}

		var grown:Bytes = Bytes.alloc(capacity);
		grown.blit(0, buffer, 0, length);
		buffer = grown;
	}

	@:noCompletion private static function __describe(value:Dynamic):String {
		var type:Class<Dynamic> = Type.getClass(value);

		if (type != null) {
			return "an instance of " + Type.getClassName(type);
		}

		return switch (Type.typeof(value)) {
			case TEnum(e): "a value of enum " + Type.getEnumName(e);
			case TFunction: "a function";
			default: "a value of type " + Std.string(Type.typeof(value));
		}
	}
}
