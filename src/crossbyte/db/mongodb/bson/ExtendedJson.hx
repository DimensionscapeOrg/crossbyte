package crossbyte.db.mongodb.bson;

import crossbyte.db.mongodb._internal.BsonWriter;
import crossbyte.db.mongodb._internal.IsoDate;
import crossbyte.errors.ArgumentError;
import haxe.Int64;
import haxe.crypto.Base64;
import haxe.io.Bytes;

/**
	MongoDB Extended JSON, version 2: JSON that can say which BSON type each
	value is.

	Plain JSON has no dates, no ObjectIds and no integers wider than a
	double's 53 bits, which is why a command sent as JSON could never set a
	TTL index's date or match an `_id`. Extended JSON writes them as small
	objects, `{"$date": "2026-09-30T00:00:00Z"}`, `{"$oid": "..."}`,
	`{"$numberLong": "9007199254740993"}`: and `parse` turns those into the
	values `Bson` encodes.

	`parse` keeps every object's field order, returning `BsonDocument`s,
	because a command's first field names the command. It also understands
	placeholders: `:name` where a value belongs is looked up and bound as that
	value, never spliced into the text, so a value cannot change the shape
	of the command it is bound into.

	```haxe
	// Given params:Map<String, Dynamic>.
	var command = ExtendedJson.parse('{"find": "sessions", "filter": {"_id": :sid}}', name -> params.get(name));
	```
**/
class ExtendedJson {
	/**
		Parses Extended JSON (canonical or relaxed, and the legacy forms of
		`$binary` and `$date`). Objects become `BsonDocument`s; type wrappers
		become their values; a number becomes an `Int`, an `Int64` when it
		needs 64 bits, or else a `Float`, and a number written with a point
		or exponent stays a double, as `BsonDouble` where its value is whole.

		`{"$regex": ..., "$options": ...}` is left a document, since in a
		filter that is the query operator; write a regular expression value as
		`{"$regularExpression": {"pattern": ..., "options": ...}}`.

		@param parameters Looks up the value for a `:name` placeholder. Any
		placeholder is refused when this is not given.
		@param exists Whether a parameter of that name exists. One that does
		is bound even when its value is `null`, as BSON null, and one that
		does not is refused. Without it, a name `parameters` answers `null`
		for is refused, a parameter set to null among them.
		@throws ArgumentError When `text` is not valid Extended JSON.
	**/
	public static function parse(text:String, ?parameters:String->Dynamic, ?exists:String->Bool):Dynamic {
		if (text == null) {
			throw new ArgumentError("Extended JSON text is null.");
		}

		var parser:ExtendedJsonParser = new ExtendedJsonParser(text, parameters, exists);
		return parser.parseDocumentText();
	}

	/**
		Writes a value as Extended JSON: relaxed by default, where numbers are
		plain JSON numbers and dates in years 1970 to 9999 are ISO text, or
		canonical, where every number and date names its type.
	**/
	public static function stringify(value:Dynamic, relaxed:Bool = true):String {
		var out:StringBuf = new StringBuf();
		__write(out, value, relaxed, 0);
		return out.toString();
	}

	@:noCompletion private static function __write(out:StringBuf, value:Dynamic, relaxed:Bool, depth:Int):Void {
		if (depth > BsonWriter.MAX_DEPTH) {
			throw new ArgumentError('A value nests more than ${BsonWriter.MAX_DEPTH} levels deep, or refers to itself.');
		}

		if (value == null) {
			out.add("null");
		} else if (Std.isOfType(value, String)) {
			quote(out, value);
		} else if (Std.isOfType(value, Bool)) {
			out.add(value ? "true" : "false");
		} else if (BsonWriter.isInt64(value) || Std.isOfType(value, BsonInt64)) {
			var text:String = Int64.toStr(Std.isOfType(value, BsonInt64) ? (value : BsonInt64).value : (value : Int64));

			if (relaxed) {
				out.add(text);
			} else {
				out.add('{"$$numberLong":"$text"}');
			}
		} else if (Std.isOfType(value, Int)) {
			var number:Int = Std.int(value);

			if (relaxed) {
				out.add(Std.string(number));
			} else {
				out.add('{"$$numberInt":"$number"}');
			}
		} else if (Std.isOfType(value, Float)) {
			__double(out, value, relaxed);
		} else if (Std.isOfType(value, BsonDouble)) {
			__double(out, (value : BsonDouble).value, relaxed);
		} else if (Std.isOfType(value, Array)) {
			var items:Array<Dynamic> = value;
			out.add("[");

			for (i in 0...items.length) {
				if (i > 0) {
					out.add(",");
				}

				__write(out, items[i], relaxed, depth + 1);
			}

			out.add("]");
		} else if (Std.isOfType(value, BsonDocument)) {
			var document:BsonDocument = value;
			out.add("{");

			for (i in 0...document.length) {
				if (i > 0) {
					out.add(",");
				}

				quote(out, document.keyAt(i));
				out.add(":");
				__write(out, document.valueAt(i), relaxed, depth + 1);
			}

			out.add("}");
		} else if (Std.isOfType(value, ObjectId)) {
			out.add('{"$$oid":"${(value : ObjectId).toHex()}"}');
		} else if (Std.isOfType(value, Date)) {
			__date(out, Int64.fromFloat(Math.ffloor((value : Date).getTime())), relaxed);
		} else if (Std.isOfType(value, BsonDateTime)) {
			__date(out, (value : BsonDateTime).millis, relaxed);
		} else if (Std.isOfType(value, Bytes)) {
			__binary(out, value, 0);
		} else if (Std.isOfType(value, BsonBinary)) {
			__binary(out, (value : BsonBinary).data, (value : BsonBinary).subtype);
		} else if (Std.isOfType(value, Decimal128)) {
			out.add('{"$$numberDecimal":"${(value : Decimal128).toString()}"}');
		} else if (Std.isOfType(value, BsonTimestamp)) {
			var timestamp:BsonTimestamp = value;
			out.add('{"$$timestamp":{"t":${__unsigned(timestamp.time)},"i":${__unsigned(timestamp.increment)}}}');
		} else if (Std.isOfType(value, BsonRegex)) {
			var regex:BsonRegex = value;
			out.add('{"$$regularExpression":{"pattern":');
			quote(out, regex.pattern);
			out.add(',"options":');
			quote(out, regex.options);
			out.add("}}");
		} else if (Std.isOfType(value, MinKey)) {
			out.add('{"$$minKey":1}');
		} else if (Std.isOfType(value, MaxKey)) {
			out.add('{"$$maxKey":1}');
		} else if (Std.isOfType(value, BsonJavaScript)) {
			var code:BsonJavaScript = value;
			out.add('{"$$code":');
			quote(out, code.code);

			if (code.scope != null) {
				out.add(',"$$scope":');
				__write(out, code.scope, relaxed, depth + 1);
			}

			out.add("}");
		} else if (Std.isOfType(value, haxe.ds.StringMap)) {
			var map:haxe.ds.StringMap<Dynamic> = value;
			var first:Bool = true;
			out.add("{");

			for (key in map.keys()) {
				if (!first) {
					out.add(",");
				}

				first = false;
				quote(out, key);
				out.add(":");
				__write(out, map.get(key), relaxed, depth + 1);
			}

			out.add("}");
		} else if (BsonWriter.isPlainObject(value)) {
			var first:Bool = true;
			out.add("{");

			for (name in Reflect.fields(value)) {
				if (!first) {
					out.add(",");
				}

				first = false;
				quote(out, name);
				out.add(":");
				__write(out, Reflect.field(value, name), relaxed, depth + 1);
			}

			out.add("}");
		} else {
			throw new ArgumentError('${Std.string(value)} has no Extended JSON form.');
		}
	}

	/** Writes `text` as a JSON string literal. **/
	public static function quote(out:StringBuf, text:String):Void {
		out.add('"');
		var start:Int = 0;

		for (i in 0...text.length) {
			var c:Int = StringTools.fastCodeAt(text, i);

			if (c >= 0x20 && c != '"'.code && c != "\\".code) {
				continue;
			}

			if (i > start) {
				out.add(text.substring(start, i));
			}

			start = i + 1;

			switch (c) {
				case '"'.code:
					out.add('\\"');
				case "\\".code:
					out.add("\\\\");
				case "\n".code:
					out.add("\\n");
				case "\r".code:
					out.add("\\r");
				case "\t".code:
					out.add("\\t");
				case 8:
					out.add("\\b");
				case 12:
					out.add("\\f");
				default:
					out.add("\\u" + StringTools.hex(c, 4));
			}
		}

		if (start < text.length) {
			out.add(start == 0 ? text : text.substring(start));
		}

		out.add('"');
	}

	@:noCompletion private static function __double(out:StringBuf, value:Float, relaxed:Bool):Void {
		if (Math.isNaN(value)) {
			out.add('{"$$numberDouble":"NaN"}');
			return;
		}

		if (!Math.isFinite(value)) {
			out.add(value > 0 ? '{"$$numberDouble":"Infinity"}' : '{"$$numberDouble":"-Infinity"}');
			return;
		}

		var text:String = Std.string(value);

		// A double is written with a point, so that it reads back a double.
		if (text.indexOf(".") < 0 && text.indexOf("e") < 0 && text.indexOf("E") < 0) {
			text += ".0";
		}

		if (relaxed) {
			out.add(text);
		} else {
			out.add('{"$$numberDouble":"$text"}');
		}
	}

	@:noCompletion private static function __date(out:StringBuf, millis:Int64, relaxed:Bool):Void {
		var total:Float = crossbyte.db.mongodb._internal.Int64Float.toFloat(millis);

		// Relaxed ISO text only for 1970 through 9999, as the specification
		// has it; everything else keeps the exact count.
		if (relaxed && total >= 0 && IsoDate.formattable(millis)) {
			out.add('{"$$date":"${IsoDate.format(millis)}"}');
		} else {
			out.add('{"$$date":{"$$numberLong":"${Int64.toStr(millis)}"}}');
		}
	}

	@:noCompletion private static function __binary(out:StringBuf, data:Bytes, subtype:Int):Void {
		out.add('{"$$binary":{"base64":"${Base64.encode(data)}","subType":"${StringTools.hex(subtype, 2).toLowerCase()}"}}');
	}

	@:noCompletion private static inline function __unsigned(value:Int):Float {
		return value < 0 ? value + 4294967296.0 : value;
	}
}

/**
	The parser behind `ExtendedJson.parse`: recursive descent over the text,
	with the position in a field.
**/
@:noCompletion
class ExtendedJsonParser {
	private var __text:String;
	private var __pos:Int = 0;
	private var __parameters:String->Dynamic;
	private var __exists:Null<String->Bool>;
	private var __depth:Int = 0;

	public function new(text:String, parameters:String->Dynamic, ?exists:String->Bool) {
		__text = text;
		__parameters = parameters;
		__exists = exists;
	}

	/** One value, and nothing after it but white space. **/
	public function parseDocumentText():Dynamic {
		__space();
		var value:Dynamic = __value();
		__space();

		if (__pos < __text.length) {
			__fail("unexpected text after the value");
		}

		return value;
	}

	private function __value():Dynamic {
		__space();

		if (__pos >= __text.length) {
			__fail("the text ends where a value should be");
		}

		var c:Int = StringTools.fastCodeAt(__text, __pos);

		switch (c) {
			case "{".code:
				return __object();
			case "[".code:
				return __array();
			case '"'.code:
				return __string();
			case "t".code:
				__literal("true");
				return true;
			case "f".code:
				__literal("false");
				return false;
			case "n".code:
				__literal("null");
				return null;
			case ":".code:
				return __placeholder();
			default:
				if (c == "-".code || (c >= "0".code && c <= "9".code)) {
					return __number();
				}

				__fail('unexpected "${String.fromCharCode(c)}"');
				return null;
		}
	}

	private function __object():Dynamic {
		if (++__depth > BsonWriter.MAX_DEPTH) {
			__fail('objects nest more than ${BsonWriter.MAX_DEPTH} levels deep');
		}

		__pos++;
		var document:BsonDocument = new BsonDocument();
		__space();

		if (__peek() == "}".code) {
			__pos++;
			__depth--;
			return document;
		}

		while (true) {
			__space();

			if (__peek() != '"'.code) {
				__fail("a field name must be a string");
			}

			var name:String = __string();
			__space();

			if (__peek() != ":".code) {
				__fail('":" expected after a field name');
			}

			__pos++;
			document.add(name, __value());
			__space();
			var next:Int = __peek();
			__pos++;

			if (next == ",".code) {
				continue;
			}

			if (next == "}".code) {
				break;
			}

			__fail('"," or "}" expected in an object');
		}

		__depth--;

		if (document.length > 0 && StringTools.fastCodeAt(document.keyAt(0), 0) == "$".code) {
			return __wrapper(document);
		}

		return document;
	}

	private function __array():Array<Dynamic> {
		if (++__depth > BsonWriter.MAX_DEPTH) {
			__fail('arrays nest more than ${BsonWriter.MAX_DEPTH} levels deep');
		}

		__pos++;
		var items:Array<Dynamic> = crossbyte.db.mongodb._internal.ValueArray.create();
		__space();

		if (__peek() == "]".code) {
			__pos++;
			__depth--;
			return items;
		}

		while (true) {
			items.push(__value());
			__space();
			var next:Int = __peek();
			__pos++;

			if (next == ",".code) {
				continue;
			}

			if (next == "]".code) {
				break;
			}

			__fail('"," or "]" expected in an array');
		}

		__depth--;
		return items;
	}

	private function __string():String {
		// Past the opening quote. Runs without escapes are copied whole.
		__pos++;
		var out:StringBuf = null;
		var start:Int = __pos;
		var text:String = __text;

		while (true) {
			if (__pos >= text.length) {
				__fail("a string is not closed");
			}

			var c:Int = StringTools.fastCodeAt(text, __pos);

			if (c == '"'.code) {
				var value:String = out == null ? text.substring(start, __pos) : {
					out.add(text.substring(start, __pos));
					out.toString();
				};
				__pos++;
				return value;
			}

			if (c < 0x20) {
				__fail("a control character inside a string must be escaped");
			}

			if (c != "\\".code) {
				__pos++;
				continue;
			}

			if (out == null) {
				out = new StringBuf();
			}

			out.add(text.substring(start, __pos));
			__pos++;

			if (__pos >= text.length) {
				__fail("a string ends inside an escape");
			}

			var escaped:Int = StringTools.fastCodeAt(text, __pos++);

			switch (escaped) {
				case '"'.code:
					out.add('"');
				case "\\".code:
					out.add("\\");
				case "/".code:
					out.add("/");
				case "b".code:
					out.addChar(8);
				case "f".code:
					out.addChar(12);
				case "n".code:
					out.add("\n");
				case "r".code:
					out.add("\r");
				case "t".code:
					out.add("\t");
				case "u".code:
					var code:Int = __hex4();

					if (code >= 0xD800 && code <= 0xDBFF && __pos + 6 <= text.length && StringTools.fastCodeAt(text, __pos) == "\\".code
						&& StringTools.fastCodeAt(text, __pos + 1) == "u".code) {
						var save:Int = __pos;
						__pos += 2;
						var low:Int = __hex4();

						if (low >= 0xDC00 && low <= 0xDFFF) {
							code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
						} else {
							__pos = save;
						}
					}

					__addCodePoint(out, code);
				default:
					__fail("an unknown escape in a string");
			}

			start = __pos;
		}
	}

	/**
		Appends a code point. On neko, whose strings are their UTF-8 bytes and
		whose `addChar` takes one byte, as those bytes.
	**/
	private static inline function __addCodePoint(out:StringBuf, code:Int):Void {
		#if target.unicode
		out.addChar(code);
		#else
		if (code < 0x80) {
			out.addChar(code);
		} else if (code < 0x800) {
			out.addChar(0xC0 | (code >> 6));
			out.addChar(0x80 | (code & 0x3F));
		} else if (code < 0x10000) {
			out.addChar(0xE0 | (code >> 12));
			out.addChar(0x80 | ((code >> 6) & 0x3F));
			out.addChar(0x80 | (code & 0x3F));
		} else {
			out.addChar(0xF0 | (code >> 18));
			out.addChar(0x80 | ((code >> 12) & 0x3F));
			out.addChar(0x80 | ((code >> 6) & 0x3F));
			out.addChar(0x80 | (code & 0x3F));
		}
		#end
	}

	private function __hex4():Int {
		if (__pos + 4 > __text.length) {
			__fail("a \\u escape needs four hexadecimal digits");
		}

		var value:Int = 0;

		for (_ in 0...4) {
			var c:Int = StringTools.fastCodeAt(__text, __pos++);
			var digit:Int = if (c >= "0".code && c <= "9".code) c - "0".code else if (c >= "a".code && c <= "f".code) c - "a".code + 10 else if (c >= "A".code
				&& c <= "F".code) c - "A".code + 10 else -1;

			if (digit < 0) {
				__fail("a \\u escape needs four hexadecimal digits");
			}

			value = (value << 4) | digit;
		}

		return value;
	}

	private function __number():Dynamic {
		var start:Int = __pos;
		var text:String = __text;
		var floating:Bool = false;

		if (StringTools.fastCodeAt(text, __pos) == "-".code) {
			__pos++;
		}

		var digitsStart:Int = __pos;

		while (__pos < text.length && __isDigit(StringTools.fastCodeAt(text, __pos))) {
			__pos++;
		}

		if (__pos == digitsStart) {
			__fail("a number needs digits");
		}

		if (__pos - digitsStart > 1 && StringTools.fastCodeAt(text, digitsStart) == "0".code) {
			__fail("a number cannot have leading zeros");
		}

		if (__pos < text.length && StringTools.fastCodeAt(text, __pos) == ".".code) {
			floating = true;
			__pos++;
			var fractionStart:Int = __pos;

			while (__pos < text.length && __isDigit(StringTools.fastCodeAt(text, __pos))) {
				__pos++;
			}

			if (__pos == fractionStart) {
				__fail("a number needs digits after its point");
			}
		}

		if (__pos < text.length && (StringTools.fastCodeAt(text, __pos) == "e".code || StringTools.fastCodeAt(text, __pos) == "E".code)) {
			floating = true;
			__pos++;

			if (__pos < text.length && (StringTools.fastCodeAt(text, __pos) == "+".code || StringTools.fastCodeAt(text, __pos) == "-".code)) {
				__pos++;
			}

			var exponentStart:Int = __pos;

			while (__pos < text.length && __isDigit(StringTools.fastCodeAt(text, __pos))) {
				__pos++;
			}

			if (__pos == exponentStart) {
				__fail("a number needs digits in its exponent");
			}
		}

		var literal:String = text.substring(start, __pos);

		if (!floating) {
			var small:Null<Int> = parseInt32(literal);

			if (small != null) {
				return small;
			}

			// Past the 32-bit range, so never one hxcpp would box as an Int.
			var wide:BsonInt64 = parseInt64(literal);

			if (wide != null) {
				var exact:Int64 = wide.value;
				return exact;
			}
		}

		var value:Float = Std.parseFloat(literal);

		// Written as a double, so kept one even where the value is whole.
		if (floating && Math.isFinite(value) && Math.ffloor(value) == value) {
			return new BsonDouble(value);
		}

		return value;
	}

	private function __placeholder():Dynamic {
		__pos++;
		var start:Int = __pos;

		while (__pos < __text.length) {
			var c:Int = StringTools.fastCodeAt(__text, __pos);

			if ((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code || (__pos > start && __isDigit(c))) {
				__pos++;
			} else {
				break;
			}
		}

		if (__pos == start) {
			__fail('":" must be followed by a parameter name');
		}

		var name:String = __text.substring(start, __pos);

		if (__parameters == null) {
			__fail('placeholder ":$name" has no parameters to take a value from');
		}

		if (__exists != null) {
			// Asked separately, so a parameter set to null is bound as BSON
			// null; told only its value, a null cannot be told from absent.
			if (!__exists(name)) {
				__fail('no parameter named "$name"');
			}

			return __parameters(name);
		}

		var value:Dynamic = __parameters(name);

		if (value == null) {
			__fail('no parameter named "$name"');
		}

		return value;
	}

	/**
		The value an Extended JSON type wrapper stands for, or the document
		itself when it is not exactly one of them, `{"$gt": 5}` is a query
		operator, not a type.
	**/
	private function __wrapper(document:BsonDocument):Dynamic {
		var key:String = document.keyAt(0);
		var value:Dynamic = document.valueAt(0);
		var single:Bool = document.length == 1;

		switch (key) {
			case "$oid" if (single && Std.isOfType(value, String) && ObjectId.isValid(value)):
				return ObjectId.fromHex(value);
			case "$symbol" if (single && Std.isOfType(value, String)):
				return value;
			case "$numberInt" if (single && Std.isOfType(value, String)):
				var parsed:Null<Int> = parseInt32(value);

				if (parsed == null) {
					__fail('"$value" is not a 32-bit integer');
				}

				return parsed;
			case "$numberLong" if (single && Std.isOfType(value, String)):
				// Kept a BsonInt64, so it is written as an int64 whatever its
				// value: see BsonInt64 for why a small one could not be.
				var parsed:BsonInt64 = parseInt64(value);

				if (parsed == null) {
					__fail('"$value" is not a 64-bit integer');
				}

				return parsed;
			case "$numberDouble" if (single && Std.isOfType(value, String)):
				return new BsonDouble(__doubleText(value));
			case "$numberDecimal" if (single && Std.isOfType(value, String)):
				return Decimal128.fromString(value);
			case "$binary":
				if (single && Std.isOfType(value, BsonDocument)) {
					var inner:BsonDocument = value;
					var base64:Dynamic = inner.get("base64");
					var subType:Dynamic = inner.get("subType");

					if (inner.length == 2 && Std.isOfType(base64, String) && Std.isOfType(subType, String)) {
						return __binary(base64, subType);
					}
				} else if (document.length == 2 && Std.isOfType(value, String) && document.keyAt(1) == "$type"
					&& Std.isOfType(document.valueAt(1), String)) {
					return __binary(value, document.valueAt(1));
				}
			case "$uuid" if (single && Std.isOfType(value, String)):
				return BsonBinary.uuidFromString(value);
			case "$code":
				if (Std.isOfType(value, String)) {
					if (single) {
						return new BsonJavaScript(value);
					}

					if (document.length == 2 && document.keyAt(1) == "$scope" && Std.isOfType(document.valueAt(1), BsonDocument)) {
						return new BsonJavaScript(value, document.valueAt(1));
					}
				}
			case "$timestamp" if (single && Std.isOfType(value, BsonDocument)):
				var inner:BsonDocument = value;

				if (inner.length == 2 && inner.exists("t") && inner.exists("i")) {
					return new BsonTimestamp(__uint32(inner.get("t")), __uint32(inner.get("i")));
				}
			case "$regularExpression" if (single && Std.isOfType(value, BsonDocument)):
				var inner:BsonDocument = value;

				if (inner.length == 2 && Std.isOfType(inner.get("pattern"), String) && Std.isOfType(inner.get("options"), String)) {
					return new BsonRegex(inner.get("pattern"), inner.get("options"));
				}
			case "$dbPointer" if (single && Std.isOfType(value, BsonDocument)):
				var inner:BsonDocument = value;

				if (inner.length == 2 && Std.isOfType(inner.get("$ref"), String) && Std.isOfType(inner.get("$id"), ObjectId)) {
					return new BsonDocument().add("$ref", inner.get("$ref")).add("$id", inner.get("$id"));
				}
			case "$date" if (single):
				return __date(value);
			// Type tests before the comparisons: on the jvm comparing a
			// Dynamic with a literal casts it to the literal's type first, and
			// {"$undefined": 1} would throw ClassCastException rather than
			// staying a document.
			case "$minKey" if (single && Std.isOfType(value, Int) && Std.int(value) == 1):
				return MinKey.VALUE;
			case "$maxKey" if (single && Std.isOfType(value, Int) && Std.int(value) == 1):
				return MaxKey.VALUE;
			case "$undefined" if (single && Std.isOfType(value, Bool) && (value : Bool)):
				return null;
			default:
		}

		return document;
	}

	private function __date(value:Dynamic):Dynamic {
		if (Std.isOfType(value, String)) {
			return BsonDateTime.parse(value);
		}

		if (Std.isOfType(value, BsonInt64)) {
			return new BsonDateTime((value : BsonInt64).value);
		}

		if (BsonWriter.isInt64(value)) {
			return new BsonDateTime(value);
		}

		if (Std.isOfType(value, Int)) {
			return new BsonDateTime(Int64.ofInt(value));
		}

		if (Std.isOfType(value, BsonDouble)) {
			return BsonDateTime.fromTime((value : BsonDouble).value);
		}

		if (Std.isOfType(value, Float)) {
			return BsonDateTime.fromTime(value);
		}

		__fail("$date needs an ISO 8601 string, a number, or {\"$numberLong\": ...}");
		return null;
	}

	private function __binary(base64:String, subType:String):Dynamic {
		var type:Int = -1;

		if (subType.length >= 1 && subType.length <= 2) {
			type = 0;

			for (i in 0...subType.length) {
				var c:Int = StringTools.fastCodeAt(subType, i);
				var digit:Int = if (c >= "0".code && c <= "9".code) c - "0".code else if (c >= "a".code && c <= "f".code) c - "a".code + 10 else if (c >= "A".code
					&& c <= "F".code) c - "A".code + 10 else -1;

				if (digit < 0) {
					type = -1;
					break;
				}

				type = (type << 4) | digit;
			}
		}

		if (type < 0) {
			__fail('"$subType" is not a binary subtype');
		}

		var data:Bytes;

		try {
			data = Base64.decode(base64);
		} catch (_:Dynamic) {
			__fail("$binary holds text that is not base64");
			return null;
		}

		return type == BsonBinary.GENERIC ? data : new BsonBinary(type, data);
	}

	private function __uint32(value:Dynamic):Int {
		var number:Float = if (Std.isOfType(value, BsonInt64)) crossbyte.db.mongodb._internal.Int64Float.toFloat((value : BsonInt64).value) else
			if (BsonWriter.isInt64(value)) crossbyte.db.mongodb._internal.Int64Float.toFloat(value) else
			if (Std.isOfType(value, Float) || Std.isOfType(value, Int)) (value : Float) else -1;

		if (number < 0 || number > 4294967295.0 || Math.ffloor(number) != number) {
			__fail("a timestamp's t and i are unsigned 32-bit integers");
		}

		return number > 2147483647.0 ? Std.int(number - 4294967296.0) : Std.int(number);
	}

	private function __doubleText(text:String):Float {
		return switch (text) {
			case "Infinity": Math.POSITIVE_INFINITY;
			case "-Infinity": Math.NEGATIVE_INFINITY;
			case "NaN": Math.NaN;
			default:
				var value:Float = Std.parseFloat(text);

				if (Math.isNaN(value)) {
					__fail('"$text" is not a number');
				}

				value;
		}
	}

	private function __literal(word:String):Void {
		if (__text.substr(__pos, word.length) != word) {
			__fail('unexpected text where "$word" was expected');
		}

		__pos += word.length;
	}

	private inline function __peek():Int {
		return __pos < __text.length ? StringTools.fastCodeAt(__text, __pos) : -1;
	}

	private function __space():Void {
		while (__pos < __text.length) {
			var c:Int = StringTools.fastCodeAt(__text, __pos);

			if (c != " ".code && c != "\t".code && c != "\n".code && c != "\r".code) {
				return;
			}

			__pos++;
		}
	}

	private function __fail(reason:String):Void {
		throw new ArgumentError('Invalid Extended JSON at character $__pos: $reason.');
	}

	private static inline function __isDigit(c:Int):Bool {
		return c >= "0".code && c <= "9".code;
	}

	/** A 32-bit decimal integer, exactly, or `null` when `text` is not one. **/
	public static function parseInt32(text:String):Null<Int> {
		var negative:Bool = text.length > 0 && StringTools.fastCodeAt(text, 0) == "-".code;
		var start:Int = negative ? 1 : 0;

		if (!__fits(text, start, negative ? "2147483648" : "2147483647")) {
			return null;
		}

		// Accumulated negative, so the most negative value is reached without
		// passing through its positive, which does not fit.
		var value:Int = 0;

		for (i in start...text.length) {
			value = value * 10 - (StringTools.fastCodeAt(text, i) - "0".code);
		}

		return negative ? value : -value;
	}

	/** A 64-bit decimal integer, exactly, or `null` when `text` is not one. **/
	public static function parseInt64(text:String):Null<BsonInt64> {
		var negative:Bool = text.length > 0 && StringTools.fastCodeAt(text, 0) == "-".code;
		var start:Int = negative ? 1 : 0;

		if (!__fits(text, start, negative ? "9223372036854775808" : "9223372036854775807")) {
			return null;
		}

		var value:Int64 = 0;
		var ten:Int64 = 10;

		for (i in start...text.length) {
			value = value * ten - Int64.ofInt(StringTools.fastCodeAt(text, i) - "0".code);
		}

		// Wrapped rather than answered as Null<Int64>, which is not a type
		// every target carries exactly.
		return new BsonInt64(negative ? value : -value);
	}

	/**
		Whether `text` from `start` is digits, without leading zeros, of a
		magnitude no greater than `limit`'s.
	**/
	private static function __fits(text:String, start:Int, limit:String):Bool {
		var count:Int = text.length - start;

		if (count <= 0 || count > limit.length) {
			return false;
		}

		for (i in start...text.length) {
			if (!__isDigit(StringTools.fastCodeAt(text, i))) {
				return false;
			}
		}

		if (count > 1 && StringTools.fastCodeAt(text, start) == "0".code) {
			return false;
		}

		return count < limit.length || text.substr(start) <= limit;
	}
}
