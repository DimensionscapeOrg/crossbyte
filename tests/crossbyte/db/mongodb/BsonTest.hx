package crossbyte.db.mongodb;

import crossbyte.db.mongodb._internal.BsonReader;
import crossbyte.db.mongodb._internal.BsonWriter;
import crossbyte.db.mongodb.bson.Bson;
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
import crossbyte.errors.IOError;
import crossbyte.test.Require;
import haxe.Int64;
import haxe.io.Bytes;
import utest.Assert;

/**
	The BSON codec against the bytes the specification says, on every target.

	MongoDB was unreachable from every CrossByte target: its only backend was
	PHP's extension, embedded in a Haxe string that stopped compiling. The
	wire client stands on this codec, so it is held to exact bytes -- the
	examples from bsonspec.org, and Decimal128 values computed independently
	with Python's decimal module -- rather than only to its own round trips,
	which a symmetric mistake would pass.

	Portable: it needs nothing but bytes, so it runs on Node and the browser
	too, where Int is a double and the encoder's arithmetic is most at risk.
**/
class BsonTest extends utest.Test {
	public function testTheSpecificationsExamplesEncodeToItsBytes():Void {
		Assert.equals("160000000268656c6c6f0006000000776f726c640000", Bson.encode({hello: "world"}).toHex());

		var awesome = new BsonDocument().add("BSON", (["awesome", 5.05, 1986] : Array<Dynamic>));
		Assert.equals("310000000442534f4e002600000002300008000000617765736f6d65000131003333333333331440103200c20700000000", Bson.encode(awesome).toHex());
	}

	public function testTheSpecificationsExamplesDecode():Void {
		var hello:Dynamic = Bson.decode(Bytes.ofHex("160000000268656c6c6f0006000000776f726c640000"));
		Assert.equals("world", hello.hello);

		var awesome:Dynamic = Bson.decode(Bytes.ofHex("310000000442534f4e002600000002300008000000617765736f6d65000131003333333333331440103200c20700000000"));
		var items:Array<Dynamic> = awesome.BSON;
		Assert.equals(3, items.length);
		Assert.equals("awesome", items[0]);
		Assert.floatEquals(5.05, items[1]);
		Assert.equals(1986, items[2]);
	}

	public function testEveryTypeSurvivesARoundTripByteForByte():Void {
		var id = ObjectId.fromHex("0123456789abcdef01234567");
		var all = new BsonDocument()
			.add("double", 1.5)
			.add("string", "text")
			.add("document", new BsonDocument().add("inner", 1))
			.add("array", ([1, "two", null] : Array<Dynamic>))
			.add("binary", Bytes.ofString("bytes"))
			.add("uuid", BsonBinary.uuidFromString("00112233-4455-6677-8899-aabbccddeeff"))
			.add("objectId", id)
			.add("true", true)
			.add("false", false)
			.add("date", BsonDateTime.parse("2040-01-01T00:00:00.250Z"))
			.add("null", null)
			.add("regex", new BsonRegex("^a.*z$", "mi"))
			.add("code", new BsonJavaScript("function() {}"))
			.add("codeWithScope", new BsonJavaScript("x + 1", new BsonDocument().add("x", 2)))
			.add("int32", -7)
			.add("timestamp", new BsonTimestamp(-1, 5))
			.add("int64", Int64.make(0x7FFFFFFF, 0xFFFFFFFF))
			.add("decimal", Decimal128.fromString("-1.23E-12"))
			.add("minKey", MinKey.VALUE)
			.add("maxKey", MaxKey.VALUE);

		var encoded:Bytes = Bson.encode(all);
		var back:BsonDocument = Bson.decode(encoded, {ordered: true, exactDates: true});

		Assert.same(all.keys(), back.keys(), "field order");
		Assert.equals(0, Bson.encode(back).compare(encoded), "re-encoded bytes differ");

		Assert.isTrue(Std.isOfType(back.get("objectId"), ObjectId));
		Assert.isTrue((back.get("objectId") : ObjectId).equals(id));
		Assert.isTrue(Std.isOfType(back.get("binary"), Bytes));
		Assert.equals(BsonBinary.UUID, (back.get("uuid") : BsonBinary).subtype);
		Assert.equals("00112233-4455-6677-8899-aabbccddeeff", (back.get("uuid") : BsonBinary).toUuidString());
		Assert.equals("2208988800250", Int64.toStr((back.get("date") : BsonDateTime).millis));
		Assert.equals("im", (back.get("regex") : BsonRegex).options);
		Assert.equals(2, ((back.get("codeWithScope") : BsonJavaScript).scope : BsonDocument).get("x"));
		Assert.equals(4294967295.0, (back.get("timestamp") : BsonTimestamp).seconds);
		Assert.equals("-1.23E-12", (back.get("decimal") : Decimal128).toString());
		Assert.equals(MinKey.VALUE, back.get("minKey"));
		Assert.equals(MaxKey.VALUE, back.get("maxKey"));
	}

	public function testInt64IsExactAndIsTestedBeforeInt():Void {
		// 2^53 + 1, which no double holds; the extremes; and 2^31, the first
		// past an Int.
		for (text in ["9007199254740993", "-9223372036854775808", "9223372036854775807", "2147483648"]) {
			var value:Int64 = Int64.parseString(text);
			var bytes:Bytes = Bson.encode({n: value});

			// Type 0x12, int64: an Int64 held in a Dynamic also passes
			// Std.isOfType(v, Int) on cpp and the jvm, so the order of the tests
			// in the encoder decides what it becomes.
			Assert.equals(0x12, bytes.get(4), 'type of $text');

			var back:Dynamic = Bson.decode(bytes).n;
			Assert.equals(text, Int64.toStr(back));
		}

		// And an Int is an int32, though hxcpp's Int64.isInt64 says yes to
		// every Int: its boxed Int64 converts from one.
		Assert.equals(0x10, Bson.encode({n: 5}).get(4));
		Assert.equals(0x10, Bson.encode({n: 1986}).get(4));
	}

	public function testAnInt64BesideADoubleStaysExact():Void {
		// On hxcpp an Array<Dynamic> widens its storage as values arrive, and
		// an Int64 and a Float together turned every Int64 into a double:
		// 9007199254740993 read back as ...992, in an array or in a document's
		// fields, whichever came first.
		var wide:Int64 = Int64.parseString("9007199254740993");
		// Built by pushing into an array that keeps its values' types: on
		// hxcpp the literal [wide, 1.5] is itself such a widening array, and
		// has made the Int64 a double before any codec sees it.
		var list:Array<Dynamic> = crossbyte.db.mongodb._internal.ValueArray.create();
		list.push(wide);
		list.push(1.5);
		var mixed = new BsonDocument()
			.add("list", list)
			.add("wide", wide)
			.add("half", 0.5);
		var bytes:Bytes = Bson.encode(mixed);

		var plain:Dynamic = Bson.decode(bytes);
		Assert.equals("9007199254740993", Int64.toStr((plain.list : Array<Dynamic>)[0]));
		Assert.equals(1.5, (plain.list : Array<Dynamic>)[1]);
		Assert.equals("9007199254740993", Int64.toStr(plain.wide));

		var ordered:BsonDocument = Bson.decode(bytes, {ordered: true});
		Assert.equals("9007199254740993", Int64.toStr(ordered.get("wide")));
		Assert.equals("9007199254740993", Int64.toStr((ordered.get("list") : Array<Dynamic>)[0]));
		Assert.equals(0, Bson.encode(ordered).compare(bytes));
	}

	public function testASmallInt64IsAnInt64WhenWrapped():Void {
		// hxcpp boxes an Int64 from -1 to 255 as the Int of the same value, so
		// held in a Dynamic it is an Int there, and goes out as one.
		var small:Int64 = Int64.ofInt(5);
		#if cpp
		Assert.equals(0x10, Bson.encode({n: small}).get(4));
		#else
		Assert.equals(0x12, Bson.encode({n: small}).get(4));
		#end

		// Wrapped, it is an int64 everywhere, and decoding with wrapInt64 keeps
		// it one through a round trip.
		var bytes:Bytes = Bson.encode({n: new BsonInt64(small)});
		Assert.equals(0x12, bytes.get(4));
		var back:Dynamic = Bson.decode(bytes, {wrapInt64: true}).n;
		Assert.isTrue(Std.isOfType(back, BsonInt64));
		Assert.equals(0, Bson.encode({n: back}).compare(bytes));
	}

	public function testNumbersAreWrittenByValue():Void {
		Assert.equals(0x10, Bson.encode({n: 5}).get(4), "a whole number in range is an int32");
		Assert.equals(0x01, Bson.encode({n: 5.5}).get(4), "a fraction is a double");
		Assert.equals(0x01, Bson.encode({n: 3e9}).get(4), "past the int32 range is a double");
		Assert.equals(0x01, Bson.encode({n: Math.POSITIVE_INFINITY}).get(4));
		Assert.equals(0x01, Bson.encode({n: new BsonDouble(5)}).get(4), "a BsonDouble is a double whatever its value");
		Assert.equals(-2147483648, Bson.decode(Bson.encode({n: -2147483648})).n);
	}

	public function testDatesAreBsonDatesSoATtlIndexActsOnThem():Void {
		var at:Float = 1790769600250.0;
		var bytes:Bytes = Bson.encode({expiresAt: Date.fromTime(at)});

		// Type 0x09, a UTC datetime, which is what a TTL index reads; the JSON
		// path this replaces could only send the date as text.
		Assert.equals(0x09, bytes.get(4));

		var exact:BsonDateTime = Bson.decode(bytes, {exactDates: true}).expiresAt;
		#if (hl || neko)
		// Date there holds whole seconds: the value encoded lost its 250 ms
		// before the codec saw it.
		Assert.equals("1790769600000", Int64.toStr(exact.millis));
		#else
		Assert.equals("1790769600250", Int64.toStr(exact.millis));
		Assert.equals(at, (Bson.decode(bytes).expiresAt : Date).getTime());
		#end

		// BsonDateTime is exact everywhere, 2038 and beyond included, and
		// before 1970. The counts are Python's datetime arithmetic.
		var far:BsonDateTime = BsonDateTime.parse("2400-02-29T23:59:59.999Z");
		var back:BsonDateTime = Bson.decode(Bson.encode({d: far}), {exactDates: true}).d;
		Assert.equals("13574649599999", Int64.toStr(back.millis));
		Assert.equals("2400-02-29T23:59:59.999Z", back.toIsoString());

		var old:BsonDateTime = BsonDateTime.parse("1965-03-04T05:06:07.008Z");
		Assert.equals("-152391232992", Int64.toStr(old.millis));
		Assert.equals("1965-03-04T05:06:07.008Z", old.toIsoString());
		Assert.equals("1790769600000", Int64.toStr(BsonDateTime.parse("2026-09-30T14:30:00+02:30").millis));
		Assert.equals("-62135596800000", Int64.toStr(BsonDateTime.parse("0001-01-01T00:00:00Z").millis));
		Assert.equals("253402300799999", Int64.toStr(BsonDateTime.parse("9999-12-31T23:59:59.999Z").millis));
		Assert.raises(() -> BsonDateTime.parse("2026-02-30T00:00:00Z"), ArgumentError);
		Assert.raises(() -> BsonDateTime.parse("2026-09-30T25:00:00Z"), ArgumentError);
		Assert.raises(() -> BsonDateTime.parse("yesterday"), ArgumentError);
	}

	public function testDecimal128MatchesIndependentlyComputedBytes():Void {
		// Hex is the 16 bytes little-endian, as stored; computed with Python's
		// decimal module and integer packing, not with this code.
		var vectors:Array<Array<String>> = [
			["0", "00000000000000000000000000004030", "0"],
			["-0", "000000000000000000000000000040b0", "-0"],
			["1", "01000000000000000000000000004030", "1"],
			["-1", "010000000000000000000000000040b0", "-1"],
			["0.1", "01000000000000000000000000003e30", "0.1"],
			["12345678901234567890123456789012340", "f2af967ed05c82de3297ff6fde3c4230", "1.234567890123456789012345678901234E+34"],
			["1234567890123456789012345678901234", "f2af967ed05c82de3297ff6fde3c4030", "1234567890123456789012345678901234"],
			["9.999999999999999999999999999999999E+6144", "ffffffff638e8d37c087adbe09edff5f", "9.999999999999999999999999999999999E+6144"],
			["1E-6176", "01000000000000000000000000000000", "1E-6176"],
			["-1E-6176", "01000000000000000000000000000080", "-1E-6176"],
			["1E+6112", "0a00000000000000000000000000fe5f", "1.0E+6112"],
			["0E+6200", "0000000000000000000000000000fe5f", "0E+6111"],
			["0E-7000", "00000000000000000000000000000000", "0E-6176"],
			["123.456", "40e20100000000000000000000003a30", "123.456"],
			["-1.23E-12", "7b0000000000000000000000000024b0", "-1.23E-12"],
			["0.001234", "d2040000000000000000000000003430", "0.001234"],
			["1.000000000000000000000000000000000E+6144", "000000000a5bc138938d44c64d31fe5f", "1.000000000000000000000000000000000E+6144"],
			["5192296858534827628530496329220095", "ffffffffffffffffffffffffffff4030", "5192296858534827628530496329220095"],
			["Infinity", "00000000000000000000000000000078", "Infinity"],
			["-Infinity", "000000000000000000000000000000f8", "-Infinity"],
			["NaN", "0000000000000000000000000000007c", "NaN"],
			["19.99", "cf070000000000000000000000003c30", "19.99"],
			["100", "64000000000000000000000000004030", "100"],
			["1E+3", "01000000000000000000000000004630", "1E+3"],
			["0.0000001234", "d2040000000000000000000000002c30", "1.234E-7"]
		];

		for (v in vectors) {
			var parsed:Decimal128 = Decimal128.fromString(v[0]);
			Assert.equals(v[1], parsed.bytes.toHex(), 'bytes of ${v[0]}');
			Assert.equals(v[2], new Decimal128(Bytes.ofHex(v[1])).toString(), 'text of ${v[1]}');
		}
	}

	public function testDecimal128RefusesWhatItWouldHaveToRound():Void {
		for (text in ["12345678901234567890123456789012345", "1E-6177", "1E+6145", "", "abc", "1.2.3", "--1", "1e", "1e+", ".", "1 "]) {
			Assert.raises(() -> Decimal128.fromString(text), ArgumentError, 'accepted "$text"');
		}
	}

	public function testNonAsciiTextRoundTripsAsUtf8():Void {
		var text:String = "Zürich \u{1F680} 中";
		var bytes:Bytes = Bson.encode({t: text});
		// 1 + 1 + ... : the string's UTF-8 length, with its NUL, is written in
		// front of it.
		var utf8:Bytes = Bytes.ofString(text);
		Assert.equals(utf8.length + 1, bytes.getInt32(7));
		Assert.equals(text, Bson.decode(bytes).t);

		// Non-ASCII field names too, which bypass the name cache. Read back by
		// the name as decoded: hxcpp cannot find a field made from a decoded
		// non-ASCII name by a literal of the same text (nor the reverse), in
		// any anonymous object, haxe.Json's included.
		var named:Dynamic = Bson.decode(Bson.encode(new BsonDocument().add("clé", 1).add("clé", 2)));
		var names:Array<String> = Reflect.fields(named);
		Assert.equals(1, names.length);
		Assert.equals("clé", names[0]);
		Assert.equals(2, Reflect.field(named, names[0]));
		var ordered:BsonDocument = Bson.decode(Bson.encode(new BsonDocument().add("日本", "語")), {ordered: true});
		Assert.equals("日本", ordered.keyAt(0));
		Assert.equals("語", ordered.valueAt(0));
	}

	public function testANulInAFieldNameIsRefusedAndInAStringIsKept():Void {
		Assert.raises(() -> Bson.encode(new BsonDocument().add("a" + String.fromCharCode(0) + "b", 1)), ArgumentError);

		var withNul:String = "a" + String.fromCharCode(0) + "b";
		Assert.equals(withNul, Bson.decode(Bson.encode({s: withNul})).s);
	}

	public function testMalformedDocumentsAreRefusedNotReadPastTheirEnd():Void {
		var good:Bytes = Bson.encode({hello: "world"});

		// Truncated.
		Assert.raises(() -> Bson.decode(good.sub(0, good.length - 1)), IOError);
		// A length larger than the bytes.
		var claimsMore:Bytes = good.sub(0, good.length);
		claimsMore.setInt32(0, 1000000);
		Assert.raises(() -> Bson.decode(claimsMore), IOError);
		// A string claiming more than its document holds. The layout: length
		// (0-3), type (4), "hello" and its NUL (5-10), the string's length
		// (11-14), "world" and its NUL (15-20), the document's NUL (21).
		var longString:Bytes = good.sub(0, good.length);
		longString.setInt32(11, 0x7FFFFFF0);
		Assert.raises(() -> Bson.decode(longString), IOError);
		// A negative string length.
		var negative:Bytes = good.sub(0, good.length);
		negative.setInt32(11, -5);
		Assert.raises(() -> Bson.decode(negative), IOError);
		// A field name run on, by its NUL overwritten, into bytes that are not
		// UTF-8: on JavaScript, Haxe's own decoding threw a RangeError there.
		var badName:Bytes = good.sub(0, good.length);
		badName.setInt32(10, -5);
		Assert.raises(() -> Bson.decode(badName), IOError);
		// Bytes that are not UTF-8 inside a string: an IOError where the
		// target's decoding refuses them, a replacement character where it
		// does not -- and never some other exception.
		var invalid:Bytes = good.sub(0, good.length);
		invalid.set(15, 0xFF);

		try {
			Bson.decode(invalid);
			Assert.pass();
		} catch (e:IOError) {
			Assert.pass();
		} catch (e:Dynamic) {
			Assert.fail("invalid UTF-8 escaped as " + Std.string(e));
		}
		// No terminating NUL.
		var unterminated:Bytes = good.sub(0, good.length);
		unterminated.set(good.length - 1, 1);
		Assert.raises(() -> Bson.decode(unterminated), IOError);
		// An unknown type.
		var unknown:Bytes = good.sub(0, good.length);
		unknown.set(4, 0x42);
		Assert.raises(() -> Bson.decode(unknown), IOError);
		// Bytes after the document.
		var trailing:Bytes = Bytes.alloc(good.length + 1);
		trailing.blit(0, good, 0, good.length);
		Assert.raises(() -> Bson.decode(trailing), IOError);
	}

	public function testNestingPastTheLimitIsRefusedBothWays():Void {
		var deep:Dynamic = {};
		var cursor:Dynamic = deep;

		for (_ in 0...(BsonWriter.MAX_DEPTH + 5)) {
			var next:Dynamic = {};
			Reflect.setField(cursor, "d", next);
			cursor = next;
		}

		Assert.raises(() -> Bson.encode(deep), ArgumentError);

		// A document that contains itself stops at the same limit rather than
		// recursing until the stack gives out.
		var cycle:Dynamic = {};
		Reflect.setField(cycle, "self", cycle);
		Assert.raises(() -> Bson.encode(cycle), ArgumentError);

		// And a hand-built document nested past it is refused on the way in.
		var levels:Int = BsonWriter.MAX_DEPTH + 10;
		var out:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
		var size:Int = 5 + levels * 8;

		for (i in 0...levels) {
			var inner:Int = size - 7 - i * 8;
			out.addInt32(size - i * 8);
			out.addByte(0x03);
			out.addByte("d".code);
			out.addByte(0);
		}

		out.addInt32(5);
		out.addByte(0);

		for (_ in 0...levels) {
			out.addByte(0);
		}

		Assert.raises(() -> Bson.decode(out.getBytes()), IOError);
	}

	public function testUnsupportedValuesAreRefusedRatherThanGuessedAt():Void {
		Assert.raises(() -> Bson.encode({when: new crossbyte.errors.Error("a class instance")}), ArgumentError);
		Assert.raises(() -> Bson.encode({f: function() {}}), ArgumentError);
		Assert.raises(() -> Bson.encode("not a document"), ArgumentError);
	}

	public function testRepeatedNamesDecodeToTheSameValues():Void {
		// Enough documents with the same names to exercise the interned names,
		// and names that collide in the cache.
		var many:Array<Dynamic> = [for (i in 0...300) {id: i, name: "n" + i, slot: i % 7}];
		var names:Array<String> = [for (i in 0...40) "field" + i];
		var wide:Dynamic = {};

		for (i in 0...names.length) {
			Reflect.setField(wide, names[i], i);
		}

		var back:Dynamic = Bson.decode(Bson.encode({items: many, wide: wide}));
		var items:Array<Dynamic> = back.items;
		Assert.equals(300, items.length);
		var bad:Int = 0;

		for (i in 0...300) {
			if (items[i].id != i || items[i].name != "n" + i || items[i].slot != i % 7) {
				bad++;
			}
		}

		Assert.equals(0, bad);

		for (i in 0...names.length) {
			Assert.equals(i, Reflect.field(back.wide, names[i]));
		}
	}

	public function testDocumentsOfOneShapeReadBackExactly():Void {
		// Enough documents of one shape, at two depths, and decoded more than
		// once by one reader, that hxcpp makes them with fixed slots from the
		// second on; an Int64 beside a Float in each, which a widening array
		// on the way would turn into a double.
		var wide:Int64 = Int64.parseString("9007199254740993");
		var items:Array<Dynamic> = [];

		for (i in 0...20) {
			items.push(new BsonDocument()
				.add("id", i)
				.add("wide", wide)
				.add("half", 0.5 + i)
				.add("name", "n" + i)
				.add("none", null)
				.add("inner", new BsonDocument().add("x", i).add("y", "y" + i)));
		}

		var bytes:Bytes = Bson.encode(new BsonDocument().add("items", items).add("ok", 1));
		var reader:BsonReader = new BsonReader();
		var bad:Int = 0;

		for (_ in 0...3) {
			var back:Dynamic = reader.readDocument(bytes, 0, bytes.length);
			var list:Array<Dynamic> = back.items;
			Assert.equals(20, list.length);
			Assert.equals(1, back.ok);

			for (i in 0...list.length) {
				var doc:Dynamic = list[i];
				var names:Array<String> = Reflect.fields(doc);
				names.sort(Reflect.compare);

				if (doc.id != i || Int64.toStr(doc.wide) != "9007199254740993" || doc.half != 0.5 + i || doc.name != "n" + i
					|| !Reflect.hasField(doc, "none") || doc.none != null || doc.inner.x != i || doc.inner.y != "y" + i
					|| names.join(",") != "half,id,inner,name,none,wide") {
					bad++;
				}
			}
		}

		Assert.equals(0, bad, "documents read back other than written");

		// They are ordinary objects: a field can be changed, added and removed.
		var doc:Dynamic = (reader.readDocument(bytes, 0, bytes.length).items : Array<Dynamic>)[3];
		doc.name = "changed";
		Reflect.setField(doc, "extra", 7);
		Assert.isTrue(Reflect.deleteField(doc, "id"));
		Assert.equals("changed", doc.name);
		Assert.equals(7, doc.extra);
		Assert.isFalse(Reflect.hasField(doc, "id"));
		Assert.equals(6, Reflect.fields(doc).length);
		var again:Dynamic = Bson.decode(Bson.encode(doc));
		Assert.equals("changed", again.name);
		Assert.equals(7, again.extra);
		Assert.equals("9007199254740993", Int64.toStr(again.wide));
	}

	public function testDocumentsOfChangingShapesReadBackExactly():Void {
		var docs:Array<Dynamic> = [];

		// The same names in two orders, alternating: two shapes.
		for (i in 0...12) {
			docs.push(i % 2 == 0 ? new BsonDocument().add("a", i).add("b", "x" + i) : new BsonDocument().add("b", "x" + i).add("a", i));
		}

		// A new shape every time, as a hostile server could send.
		for (i in 0...12) {
			docs.push(new BsonDocument().add("k" + i, i).add("v", i));
		}

		// A name repeated within a document: the last value wins.
		for (i in 0...3) {
			docs.push(new BsonDocument().add("dup", i).add("dup", i + 100));
		}

		// A name longer than the table interns, and more fields than a slot
		// layout is made for.
		var long:String = StringTools.lpad("", "l", 40);

		for (i in 0...3) {
			docs.push(new BsonDocument().add(long, i).add("s", i));
		}

		for (i in 0...3) {
			var many:BsonDocument = new BsonDocument();

			for (f in 0...70) {
				many.add("f" + f, f + i);
			}

			docs.push(many);
		}

		// Empty ones.
		for (_ in 0...3) {
			docs.push(new BsonDocument());
		}

		var bytes:Bytes = Bson.encode(new BsonDocument().add("docs", docs));
		var reader:BsonReader = new BsonReader();
		var failures:Array<String> = [];

		for (round in 0...2) {
			var back:Array<Dynamic> = reader.readDocument(bytes, 0, bytes.length).docs;
			Assert.equals(docs.length, back.length);

			for (i in 0...back.length) {
				var sent:BsonDocument = docs[i];
				var got:Dynamic = back[i];
				var expected:Map<String, Dynamic> = new Map();

				for (k in 0...sent.length) {
					expected.set(sent.keyAt(k), sent.valueAt(k));
				}

				var names:Array<String> = Reflect.fields(got);
				var count:Int = 0;

				for (name in expected.keys()) {
					count++;

					if (!Reflect.hasField(got, name) || Reflect.field(got, name) != expected.get(name)) {
						failures.push('round $round document $i field $name');
					}
				}

				if (names.length != count) {
					failures.push('round $round document $i has ${names.length} fields, not $count');
				}
			}
		}

		Assert.same([], failures);
	}

	public function testOrderedDecodingKeepsTheStoredOrder():Void {
		var document = new BsonDocument().add("zeta", 1).add("alpha", 2).add("mid", 3);
		var back:BsonDocument = Bson.decode(Bson.encode(document), {ordered: true});
		Assert.same(["zeta", "alpha", "mid"], back.keys());
	}

	public function testObjectIdsAreUniqueAndCarryTheirSecond():Void {
		var a = new ObjectId();
		var b = new ObjectId();
		Assert.isFalse(a.equals(b));
		Assert.equals(24, a.toHex().length);
		Assert.isTrue(ObjectId.fromHex(a.toHex()).equals(a));
		Assert.isTrue(ObjectId.fromHex(a.toHex().toUpperCase()).equals(a));

		// time of day: an ObjectId carries the second it was made in.
		var now:Float = Date.now().getTime() / 1000;
		Assert.isTrue(Math.abs(a.getTimestamp() - now) < 120, 'timestamp ${a.getTimestamp()} against $now');

		Assert.isFalse(ObjectId.isValid("0123456789abcdef0123456"));
		Assert.isFalse(ObjectId.isValid("0123456789abcdef0123456g"));
		Assert.raises(() -> ObjectId.fromHex("nope"), ArgumentError);

		var seen:Map<String, Bool> = new Map();
		var distinct:Int = 0;

		for (_ in 0...2000) {
			var hex:String = new ObjectId().toHex();

			if (!seen.exists(hex)) {
				seen.set(hex, true);
				distinct++;
			}
		}

		Assert.equals(2000, distinct);
	}

	public function testOldBinaryCarriesItsInnerLength():Void {
		var old = new BsonBinary(BsonBinary.BINARY_OLD, Bytes.ofString("abc"));
		var bytes:Bytes = Bson.encode({b: old});
		// Outer length 7: the inner length's four bytes and the data.
		Assert.equals(7, bytes.getInt32(7));
		Assert.equals(3, bytes.getInt32(12));
		var back:BsonBinary = Bson.decode(bytes).b;
		Assert.equals("abc", back.data.toString());
	}

	public function testWritingForAnInsertPutsTheIdFirst():Void {
		var writer = new BsonWriter();
		var id:Dynamic = writer.documentWithId({name: "x", count: 1});
		Require.notNull(id);
		Assert.isTrue(Std.isOfType(id, ObjectId));
		var back:BsonDocument = Bson.decode(writer.toBytes(), {ordered: true});
		Assert.equals("_id", back.keyAt(0));
		Assert.isTrue((back.get("_id") : ObjectId).equals(id));

		// One that has an _id keeps it.
		var given = new BsonWriter();
		Assert.equals("mine", given.documentWithId(new BsonDocument().add("a", 1).add("_id", "mine")));
	}
}
