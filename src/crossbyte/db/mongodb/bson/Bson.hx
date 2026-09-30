package crossbyte.db.mongodb.bson;

import crossbyte.db.mongodb._internal.BsonReader;
import crossbyte.db.mongodb._internal.BsonWriter;
import haxe.io.Bytes;

/**
	How `Bson.decode` builds what it reads.
**/
typedef BsonReadOptions = {
	/**
		Dates as `BsonDateTime`, exact everywhere, rather than `Date`, which
		holds whole seconds between 1901 and 2038 on hl and neko.
	**/
	@:optional var exactDates:Bool;

	/** Documents as `BsonDocument`, in their stored order, rather than anonymous objects. **/
	@:optional var ordered:Bool;

	/**
		int64 values as `BsonInt64` rather than `haxe.Int64`, so they are
		written back as int64 whatever their value, on hxcpp a small
		`haxe.Int64` in a `Dynamic` cannot be told from an `Int`.
	**/
	@:optional var wrapInt64:Bool;
}

/**
	Encodes and decodes BSON documents.

	What each Haxe value becomes, and what each BSON type reads back as:

	| BSON type | Haxe |
	| --- | --- |
	| double | `Float` (or `BsonDouble`, to force a double) |
	| string | `String` |
	| document | anonymous object, `BsonDocument` or `StringMap` |
	| array | `Array` |
	| binary | `haxe.io.Bytes` (subtype 0) or `BsonBinary` |
	| ObjectId | `ObjectId` |
	| bool | `Bool` |
	| UTC datetime | `Date`, or `BsonDateTime` |
	| null | `null` |
	| regex | `BsonRegex` |
	| JavaScript | `BsonJavaScript` |
	| int32 | `Int` |
	| timestamp | `BsonTimestamp` |
	| int64 | `haxe.Int64`, exactly |
	| Decimal128 | `Decimal128`, exactly |
	| MinKey, MaxKey | `MinKey.VALUE`, `MaxKey.VALUE` |

	A number is written by its value: a whole number in the 32-bit range as
	int32, any other as a double, see `BsonDouble` for why the Haxe type
	cannot decide. The deprecated types read as their nearest form: undefined
	as `null`, a symbol as its `String`, a DBPointer as `{$ref, $id}`.
**/
class Bson {
	/**
		Encodes a document: an anonymous object, a `BsonDocument` or a
		`StringMap`.

		@throws crossbyte.errors.ArgumentError When a value has no BSON form,
		or a field name holds a NUL.
	**/
	public static function encode(document:Dynamic):Bytes {
		var writer:BsonWriter = new BsonWriter(256);
		writer.document(document, 0);
		return writer.toBytes();
	}

	/**
		Decodes the document at the start of `bytes`, which must hold exactly
		one.

		@throws crossbyte.errors.IOError When the bytes are not one
		well-formed document.
	**/
	public static function decode(bytes:Bytes, ?options:BsonReadOptions):Dynamic {
		var reader:BsonReader = new BsonReader();

		if (options != null) {
			reader.exactDates = options.exactDates == true;
			reader.ordered = options.ordered == true;
			reader.wrapInt64 = options.wrapInt64 == true;
		}

		var document:Dynamic = reader.readDocument(bytes, 0, bytes.length);

		if (reader.end != bytes.length) {
			throw new crossbyte.errors.IOError('Malformed BSON: ${bytes.length - reader.end} bytes follow the document.');
		}

		return document;
	}
}
