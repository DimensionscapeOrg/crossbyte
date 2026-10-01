package crossbyte.db.mongodb;

import crossbyte.db.mongodb.bson.Bson;
import crossbyte.db.mongodb.bson.BsonBinary;
import crossbyte.db.mongodb.bson.BsonDateTime;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.BsonDouble;
import crossbyte.db.mongodb.bson.BsonInt64;
import crossbyte.db.mongodb.bson.BsonRegex;
import crossbyte.db.mongodb.bson.BsonTimestamp;
import crossbyte.db.mongodb.bson.Decimal128;
import crossbyte.db.mongodb.bson.ExtendedJson;
import crossbyte.db.mongodb.bson.MaxKey;
import crossbyte.db.mongodb.bson.MinKey;
import crossbyte.db.mongodb.bson.ObjectId;
import crossbyte.errors.ArgumentError;
import haxe.Int64;
import haxe.io.Bytes;
import utest.Assert;

/**
	Extended JSON, the text a command can be written in.

	The old driver decoded command text with PHP's json_decode, so a command
	had no way to carry a date, an ObjectId or a 64-bit integer: a session's
	`expiresAt` went to the server as a string, and the TTL index meant to
	delete it never did. These hold the type wrappers to what they stand for,
	and placeholders to being bound as values.
**/
class ExtendedJsonTest extends utest.Test {
	public function testTypeWrappersBecomeTheirValues():Void {
		var parsed:BsonDocument = ExtendedJson.parse('{"oid": {"$$oid": "0123456789abcdef01234567"},'
			+ ' "long": {"$$numberLong": "9007199254740993"},'
			+ ' "int": {"$$numberInt": "-2147483648"},'
			+ ' "double": {"$$numberDouble": "-Infinity"},'
			+ ' "decimal": {"$$numberDecimal": "19.99"},'
			+ ' "date": {"$$date": {"$$numberLong": "1790769600250"}},'
			+ ' "relaxedDate": {"$$date": "2026-09-30T12:00:00.250Z"},'
			+ ' "legacyDate": {"$$date": 1790769600250},'
			+ ' "binary": {"$$binary": {"base64": "AQID", "subType": "00"}},'
			+ ' "uuid": {"$$binary": {"base64": "ABEiM0RVZneImaq7zN3u/w==", "subType": "04"}},'
			+ ' "legacyBinary": {"$$binary": "AQID", "$$type": "80"},'
			+ ' "timestamp": {"$$timestamp": {"t": 4294967295, "i": 7}},'
			+ ' "regex": {"$$regularExpression": {"pattern": "^a", "options": "xi"}},'
			+ ' "min": {"$$minKey": 1},'
			+ ' "max": {"$$maxKey": 1},'
			+ ' "undefined": {"$$undefined": true}}');

		Assert.isTrue((parsed.get("oid") : ObjectId).equals(ObjectId.fromHex("0123456789abcdef01234567")));
		Assert.equals("9007199254740993", Int64.toStr((parsed.get("long") : BsonInt64).value));
		Assert.equals(-2147483648, parsed.get("int"));
		Assert.equals(Math.NEGATIVE_INFINITY, (parsed.get("double") : BsonDouble).value);
		Assert.equals("19.99", (parsed.get("decimal") : Decimal128).toString());

		for (key in ["date", "relaxedDate", "legacyDate"]) {
			Assert.equals("1790769600250", Int64.toStr((parsed.get(key) : BsonDateTime).millis), key);
		}

		Assert.equals("010203", (parsed.get("binary") : Bytes).toHex());
		Assert.equals("00112233-4455-6677-8899-aabbccddeeff", (parsed.get("uuid") : BsonBinary).toUuidString());
		Assert.equals(0x80, (parsed.get("legacyBinary") : BsonBinary).subtype);
		Assert.equals(4294967295.0, (parsed.get("timestamp") : BsonTimestamp).seconds);
		Assert.equals(7, (parsed.get("timestamp") : BsonTimestamp).increment);
		Assert.equals("ix", (parsed.get("regex") : BsonRegex).options);
		Assert.equals(MinKey.VALUE, parsed.get("min"));
		Assert.equals(MaxKey.VALUE, parsed.get("max"));
		Assert.isNull(parsed.get("undefined"));
		Assert.isTrue(parsed.exists("undefined"));

		// And they reach BSON as their types: a date, not text; and a
		// {"$numberLong": "5"} an int64, on hxcpp too, where a small Int64 in
		// a Dynamic would have been an Int.
		var bytes:Bytes = Bson.encode(new BsonDocument().add("d", parsed.get("date")));
		Assert.equals(0x09, bytes.get(4));
		Assert.equals(0x12, Bson.encode(new BsonDocument().add("n", ExtendedJson.parse('{"$$numberLong": "5"}'))).get(4));
	}

	public function testPlainNumbersKeepTheirWidth():Void {
		var parsed:BsonDocument = ExtendedJson.parse('{"small": 5, "wide": 9007199254740993, "huge": 1e400, "fraction": 2.5, "whole": 5.0, "exp": 1e3, "neg": -0}');
		Assert.equals(5, parsed.get("small"));
		Assert.equals("9007199254740993", Int64.toStr(parsed.get("wide")));
		Assert.equals(Math.POSITIVE_INFINITY, parsed.get("huge"));
		Assert.equals(2.5, parsed.get("fraction"));
		// Written with a point or an exponent: a double, even when whole.
		Assert.equals(5.0, (parsed.get("whole") : BsonDouble).value);
		Assert.equals(1000.0, (parsed.get("exp") : BsonDouble).value);
		Assert.equals(0x01, Bson.encode(new BsonDocument().add("x", parsed.get("whole"))).get(4));
		Assert.equals(0, parsed.get("neg"));
	}

	public function testFieldOrderIsKeptBecauseTheCommandNameIsTheFirstField():Void {
		var parsed:BsonDocument = ExtendedJson.parse('{"find": "c", "filter": {}, "sort": {"z": 1, "a": -1, "m": 1}}');
		Assert.same(["find", "filter", "sort"], parsed.keys());
		Assert.same(["z", "a", "m"], (parsed.get("sort") : BsonDocument).keys());
	}

	public function testPlaceholdersAreBoundAsValuesNotSplicedAsText():Void {
		var hostile:String = '"}, "drop": "users", "x": {"';
		var when:BsonDateTime = BsonDateTime.parse("2026-09-30T00:00:00Z");
		var values:Map<String, Dynamic> = ["sid" => hostile, "when" => when, "n" => Int64.make(1, 0)];
		var parsed:BsonDocument = ExtendedJson.parse('{"find": "sessions", "filter": {"_id": :sid, "at": {"$$gt": :when}, "n": :n}}', name -> values.get(name));

		var filter:BsonDocument = parsed.get("filter");
		// The whole string, as one value: nothing in it became structure.
		Assert.equals(hostile, filter.get("_id"));
		Assert.same(["find", "filter"], parsed.keys());
		Assert.equals(when, (filter.get("at") : BsonDocument).get("$gt"));
		Assert.equals("4294967296", Int64.toStr(filter.get("n")));

		// Inside a string a colon is text.
		Assert.equals("a :sid b", ExtendedJson.parse('{"s": "a :sid b"}', name -> values.get(name)).get("s"));

		Assert.raises(() -> ExtendedJson.parse('{"_id": :missing}', name -> values.get(name)), ArgumentError);
		Assert.raises(() -> ExtendedJson.parse('{"_id": :sid}'), ArgumentError);
	}

	public function testAParameterThatExistsIsBoundEvenWhenNull():Void {
		// Asked for a value alone, a null meant no such parameter, so one set
		// to null was refused. Given whether it exists, it is bound as null.
		var values:Map<String, Dynamic> = ["email" => null];
		var parsed:BsonDocument = ExtendedJson.parse('{"email": :email}', name -> values.get(name), name -> values.exists(name));
		Assert.same(["email"], parsed.keys());
		Assert.isNull(parsed.get("email"));
		Assert.raises(() -> ExtendedJson.parse('{"x": :missing}', name -> values.get(name), name -> values.exists(name)), ArgumentError);
	}

	public function testTheRegexQueryOperatorStaysAnOperator():Void {
		// In a filter, {"$regex": ..., "$options": ...} is the operator, and
		// has to reach the server as a document.
		var parsed:BsonDocument = ExtendedJson.parse('{"name": {"$$regex": "^a", "$$options": "i"}, "q": {"$$gt": 5}}');
		Assert.isTrue(Std.isOfType(parsed.get("name"), BsonDocument));
		Assert.equals("^a", (parsed.get("name") : BsonDocument).get("$regex"));
		Assert.equals(5, (parsed.get("q") : BsonDocument).get("$gt"));
	}

	public function testStringEscapesIncludingASurrogatePair():Void {
		var parsed:BsonDocument = ExtendedJson.parse('{"s": "q\\"b\\\\n\\n\\t\\u00e9\\ud83d\\ude80/\\/"}');
		Assert.equals('q"b\\n\n\té\u{1F680}//', parsed.get("s"));
	}

	public function testMalformedTextIsRefused():Void {
		for (text in ['{', '{"a" 1}', '{"a": 1,}', '[1 2]', '{"a": tru}', '{"a": 01}', '{"a": "\\x"}', '{"a": 1} x', '{"$$oid": "short"}x',
			'{"a": {"$$numberLong": "9223372036854775808"}}', '{"a": {"$$numberInt": "2147483648"}}', '{"a": {"$$date": "not a date"}}']) {
			Assert.raises(() -> ExtendedJson.parse(text), ArgumentError, 'accepted $text');
		}
	}

	public function testStringifyAndParseAgree():Void {
		var document = new BsonDocument()
			.add("id", ObjectId.fromHex("0123456789abcdef01234567"))
			.add("n", 5)
			.add("l", Int64.make(0x12345678, 0x9ABCDEF0))
			.add("d", BsonDateTime.parse("1965-03-04T05:06:07.008Z"))
			.add("dec", Decimal128.fromString("-0.00"))
			.add("s", 'tab\tquote"')
			.add("arr", ([1, new BsonDocument().add("x", true)] : Array<Dynamic>));

		for (relaxed in [true, false]) {
			var text:String = ExtendedJson.stringify(document, relaxed);
			var back:BsonDocument = ExtendedJson.parse(text);
			Assert.equals(0, Bson.encode(back).compare(Bson.encode(document)), 'relaxed=$relaxed: $text');
		}

		Assert.equals('{"n":{"$$numberInt":"5"}}', ExtendedJson.stringify({n: 5}, false));
		Assert.equals('{"d":{"$$date":"2026-09-30T12:00:00.250Z"}}', ExtendedJson.stringify({d: BsonDateTime.parse("2026-09-30T12:00:00.250Z")}));
		// Before 1970, the count, as the specification has it.
		Assert.equals('{"d":{"$$date":{"$$numberLong":"-152391232992"}}}', ExtendedJson.stringify({d: BsonDateTime.parse("1965-03-04T05:06:07.008Z")}));
	}
}
