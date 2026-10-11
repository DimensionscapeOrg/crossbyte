package crossbyte.foundation;

import crossbyte.FieldStruct;
import crossbyte.Object;
import crossbyte.PrimitiveValue;
import crossbyte.Seq32;
import crossbyte.TypedObject;
import crossbyte.ds.TypeCheck;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.RangeError;
import utest.Assert;

private typedef SamplePayload = {
	var id:Int;
	var name:String;
}

class FoundationConstructsTest extends utest.Test {
	public function testFieldStructSupportsFieldAndArrayAccess():Void {
		var fields:FieldStruct<Int> = new FieldStruct();
		fields.count = 3;
		fields["size"] = 5;

		Assert.equals(3, fields.count);
		Assert.equals(5, fields["size"]);
		Assert.isTrue(FieldStruct.exists(fields, "count"));
		Assert.equals(5, FieldStruct.get(fields, "size"));

		var seen = [];
		for (entry in FieldStruct.iterator(fields)) {
			seen.push(entry.key + "=" + entry.value);
		}

		Assert.isTrue(seen.indexOf("count=3") != -1);
		Assert.isTrue(seen.indexOf("size=5") != -1);

		FieldStruct.delete(fields, "count");
		Assert.isFalse(FieldStruct.exists(fields, "count"));

		FieldStruct.clear(fields);
		Assert.isFalse(FieldStruct.exists(fields, "size"));
	}

	public function testFieldStructProvidesKeyValueAndObjectViews():Void {
		var fields:FieldStruct<Int> = new FieldStruct();
		fields.alpha = 10;
		fields["beta"] = 20;

		var keys = [];
		for (key in fields.keys()) {
			keys.push(key);
		}

		Assert.isTrue(keys.indexOf("alpha") != -1);
		Assert.isTrue(keys.indexOf("beta") != -1);

		var values = [];
		for (value in fields.values()) {
			values.push(value);
		}

		Assert.isTrue(values.indexOf(10) != -1);
		Assert.isTrue(values.indexOf(20) != -1);

		var entries = [];
		for (entry in fields.entries()) {
			entries.push(entry.key + "=" + entry.value);
		}

		Assert.isTrue(entries.indexOf("alpha=10") != -1);
		Assert.isTrue(entries.indexOf("beta=20") != -1);

		var object = fields.toObject();
		Assert.equals(10, object["alpha"]);
		Assert.equals(20, object["beta"]);
	}

	/**
		A `FieldStruct` is walked by a key and value loop, as its
		documentation says. It did not compile: it had no `keyValueIterator`
		(and its static `iterator` refuses a plain `for (x in fields)`).
	**/
	public function testFieldStructIsWalkedByAKeyValueLoop():Void {
		var fields:FieldStruct<Int> = new FieldStruct();
		fields.alpha = 1;
		fields["beta"] = 2;
		fields["keys"] = 3;
		var seen:Array<String> = [];
		for (name => value in fields) {
			seen.push(name + "=" + value);
		}
		seen.sort(Reflect.compare);
		Assert.same(["alpha=1", "beta=2", "keys=3"], seen);
		Assert.equals(3, fields["keys"]);
	}

	public function testObjectIteratesDynamicFields():Void {
		var object:Object = new Object();
		object.alpha = "a";
		object.beta = 2;
		object["gamma"] = true;

		var fields = [];
		for (field in object) {
			fields.push(field);
		}

		Assert.isTrue(fields.indexOf("alpha") != -1);
		Assert.isTrue(fields.indexOf("beta") != -1);
		Assert.isTrue(fields.indexOf("gamma") != -1);
	}

	public function testObjectSupportsBracketAccessAndIntrospection():Void {
		var object:Object = new Object();
		object["first"] = "value";
		object["second"] = 2;

		Assert.equals("value", object["first"]);
		Assert.equals(2, object["second"]);
		Assert.isTrue(object.exists("first"));
		Assert.isFalse(object.exists("missing"));

		var sortedKeys = object.keys();
		sortedKeys.sort(Reflect.compare);
		Assert.same(["first", "second"], sortedKeys);
		Assert.equals(2, object.values().length);

		var entries = [];
		for (entry in object.entries()) {
			entries.push(entry.key + "=" + Std.string(entry.value));
		}

		Assert.isTrue(entries.indexOf("first=value") != -1);
		Assert.isTrue(entries.indexOf("second=2") != -1);
		Assert.isTrue(object.remove("first"));
		Assert.isFalse(object.exists("first"));
	}

	/**
		A null `Object` or `TypedObject` answers as an empty one, on every
		target. `exists` threw on the jvm and Node, `keys`, `values` and
		`entries` on the jvm, and `remove` on Node and neko, where the others
		answered false and nothing.
	**/
	public function testANullObjectAnswersAsAnEmptyOne():Void {
		var object:Object = null;
		Assert.isFalse(object.exists("a"));
		Assert.isFalse(object.remove("a"));
		Assert.equals(0, object.keys().length);
		Assert.equals(0, object.values().length);
		Assert.isFalse(object.entries().hasNext());
		Assert.isNull(object.get("a"));
		var visited:Int = 0;
		for (_ in object) {
			visited++;
		}
		Assert.equals(0, visited);

		var typed:TypedObject<SamplePayload> = null;
		Assert.isFalse(typed.exists("id"));
		Assert.equals(0, typed.keys().length);
		Assert.equals(0, typed.values().length);
		Assert.isFalse(typed.entries().hasNext());
		Assert.isNull(typed["id"]);
	}

	/**
		`__proto__` and `constructor` are fields like any other, on every
		target. On JavaScript `get("__proto__")` read a plain object's
		prototype, which is every plain object's, so a path of names a peer
		chose, walked by `get` and finished by `set`, gave every object in the
		process a field; and `set("__proto__", ...)` replaced the object's
		prototype, so what it held was read as the object's own fields.
	**/
	public function testProtoAndConstructorAreOrdinaryFields():Void {
		var plain:Object = new Object();
		Assert.isNull(plain.get("__proto__"), "a plain object's __proto__ was read");
		Assert.isNull(plain.get("constructor"), "a plain object's constructor was read");

		for (path in [["__proto__", "cbPolluted"], ["constructor", "prototype", "cbPolluted"]]) {
			var step:Object = new Object();
			for (i in 0...path.length - 1) {
				var next:Object = step.get(path[i]);
				if (next == null) {
					next = new Object();
					step.set(path[i], next);
				}
				step = next;
			}
			step.set(path[path.length - 1], "yes");
			var fresh:Object = new Object();
			var reached:Dynamic = fresh.get("cbPolluted");
			#if js
			js.Syntax.code("delete Object.prototype.cbPolluted");
			#end
			Assert.isNull(reached, path.join(".") + " reached every object");
		}

		var shadow:Object = new Object();
		shadow.set("__proto__", {admin: true});
		Assert.isTrue(shadow.exists("__proto__"), "__proto__ was not set as a field");
		Assert.same(["__proto__"], shadow.keys());
		Assert.isNull(shadow.get("admin"), "a field set as __proto__ was read as the object's own");
		Assert.equals(true, (shadow.get("__proto__") : Dynamic).admin);

		var fields:FieldStruct<String> = new FieldStruct();
		fields["__proto__"] = "p";
		Assert.equals("p", fields.toObject().get("__proto__"), "toObject lost __proto__");

		var parsed:Object = haxe.Json.parse('{"__proto__":{"admin":true},"constructor":2}');
		Assert.equals(2, parsed.get("constructor"));
		Assert.isNull(parsed.get("admin"));

		var typed:TypedObject<Dynamic> = TypedObject.of(new Object());
		typed["__proto__"] = {admin: true};
		Assert.isNull(typed["admin"]);
		Assert.isTrue(typed.exists("__proto__"));
	}

	public function testPrimitiveValueCastsAcrossSupportedPrimitives():Void {
		var intValue:PrimitiveValue = 42;
		var stringValue:PrimitiveValue = "123";
		var boolValue:PrimitiveValue = false;
		var nanValue:PrimitiveValue = Math.NaN;
		var nullValue:PrimitiveValue = cast null;

		var asString:String = intValue;
		var asInt:Int = stringValue;
		var asBool:Bool = boolValue;
		var asFloat:Float = nanValue;
		var nullAsBool:Bool = nullValue;

		Assert.equals("42", asString);
		Assert.equals(123, asInt);
		Assert.isFalse(asBool);
		Assert.floatEquals(0.0, asFloat);
		Assert.isFalse(nullAsBool);
	}

	/**
		A null `String` stays null. It was held as `""`, so it read as a
		string, `toInt` threw where null converts to 0, `toFloat` was NaN
		where null is 0, and it came back as `""`.
	**/
	public function testPrimitiveValueKeepsANullStringNull():Void {
		var text:Null<String> = null;
		var value:PrimitiveValue = text;
		Assert.isTrue(value.isNull(), "a null String was not null");
		Assert.isFalse(value.isString(), "a null String was a string");
		var back:String = value;
		Assert.isNull(back, "a null String came back as " + back);
		Assert.isFalse(value.toBool());
		Assert.equals(0.0, value.toFloat());
		var whole:Int = -1;
		try {
			whole = value.toInt();
		} catch (_:Dynamic) {}
		Assert.equals(0, whole, "a null String did not convert to 0");

		var nothing:PrimitiveValue = cast null;
		Assert.isNull(nothing.toString());
		var empty:PrimitiveValue = "";
		Assert.isTrue(empty.isString());
		Assert.equals("", (empty : String));
	}

	public function testPrimitiveValueFloatToIntTruncates():Void {
		var positive:PrimitiveValue = 3.9;
		var negative:PrimitiveValue = -2.7;

		var posInt:Int = positive;
		var negInt:Int = negative;

		Assert.equals(3, posInt);
		Assert.equals(-2, negInt);
	}

	/**
		A string reads as the same `Int` on every target, or not at all.
		`Std.parseInt` gives "4294967396" as null on eval, as that number on
		Node and as a thrown NumberFormatException on the jvm, and reads "12abc"
		as 12.
	**/
	public function testPrimitiveValueParsesIntegersTheSameOnEveryTarget():Void {
		function int(text:String):Int {
			var value:PrimitiveValue = text;
			return value.toInt();
		}
		Assert.equals(42, int("42"));
		Assert.equals(7, int(" 7 "));
		Assert.equals(5, int("+5"));
		Assert.equals(7, int("007"));
		Assert.equals(2147483647, int("2147483647"));
		Assert.equals(-2147483647 - 1, int("-2147483648"));
		Assert.equals(-2147483647 - 1, int("-0002147483648"));
		Assert.equals(31, int("0x1F"));
		Assert.equals(-16, int("-0X10"));
		Assert.equals(-2147483647 - 1, int("-0x80000000"));
		for (big in ["4294967396", "99999999999", "2147483648", "-2147483649", "0x100000000", " -0x80000001 "]) {
			Assert.raises(() -> int(big), RangeError, '"$big" was read as a number');
		}
		for (bad in ["abc", "12abc", "", "   ", "-", "0x", "1e3", "--1", "0xg", "1.5"]) {
			Assert.raises(() -> int(bad), ArgumentError, '"$bad" was read as a number');
		}
	}

	/**
		A Float outside the range of `Int` does not become one. `Std.int` of
		3e9 is 2147483647 on the jvm and -1294967296 on eval and Node.
	**/
	public function testPrimitiveValueFloatOutsideTheIntRangeThrows():Void {
		function int(f:Float):Int {
			var value:PrimitiveValue = f;
			return value.toInt();
		}
		Assert.equals(2147483647, int(2147483647.9));
		Assert.equals(-2147483647 - 1, int(-2147483648.9));
		Assert.equals(-3, int(-3.99));
		for (bad in [3e9, -3e9, 2147483648.0, -2147483649.0, Math.POSITIVE_INFINITY, Math.NEGATIVE_INFINITY]) {
			Assert.raises(() -> int(bad), RangeError, bad + " became an Int");
		}
	}

	/**
		A conversion `PrimitiveValue` cannot make throws one of CrossByte's
		own errors, as every other refusal does: a `RangeError` for a number
		outside the type's range and an `ArgumentError` for anything else.
		It threw a `String`, which a `catch (e:Error)` let through.
	**/
	public function testPrimitiveValueThrowsTypedErrors():Void {
		function thrown(f:Void->Void):Dynamic {
			try {
				f();
			} catch (e:Dynamic) {
				return e;
			}
			return null;
		}
		var big:PrimitiveValue = "4294967396";
		var huge:PrimitiveValue = 3e9;
		var word:PrimitiveValue = "abc";
		var structure:PrimitiveValue = cast {nested: true};
		var nan:PrimitiveValue = PrimitiveValue.fromDynamic(Math.NaN);

		var range:Dynamic = thrown(() -> big.toInt());
		Assert.isTrue(Std.isOfType(range, RangeError), "a string of digits past Int threw " + range);
		Assert.isTrue(Std.isOfType(thrown(() -> huge.toInt()), RangeError));
		var notANumber:Dynamic = thrown(() -> word.toInt());
		Assert.isTrue(Std.isOfType(notANumber, ArgumentError), "text that is not a number threw " + notANumber);
		Assert.isTrue(Std.isOfType(thrown(() -> nan.toInt()), ArgumentError), "NaN as an Int");
		Assert.isTrue(Std.isOfType(thrown(() -> structure.toInt()), ArgumentError));
		Assert.isTrue(Std.isOfType(thrown(() -> structure.toFloat()), ArgumentError));
		Assert.isTrue(Std.isOfType(thrown(() -> structure.toBool()), ArgumentError));
		var refused:Dynamic = thrown(() -> PrimitiveValue.fromDynamic({nested: true}));
		Assert.isTrue(Std.isOfType(refused, ArgumentError), "fromDynamic threw " + refused);

		// Each says what it was given.
		if (Std.isOfType(range, crossbyte.errors.Error)) {
			Assert.isTrue((range : crossbyte.errors.Error).message.indexOf("4294967396") >= 0, (range : crossbyte.errors.Error).message);
		}
		if (Std.isOfType(notANumber, crossbyte.errors.Error)) {
			Assert.isTrue((notANumber : crossbyte.errors.Error).message.indexOf("abc") >= 0, (notANumber : crossbyte.errors.Error).message);
		}
	}

	/**
		A string reads as the same `Float` on every target, and as a number
		only if it is one. Through `Std.parseFloat`, "0x10" was 16 natively
		and on neko and 0 elsewhere, "Infinity" NaN on eval and the jvm and
		"inf" Infinity only natively and on neko, and "12abc" was 12.
	**/
	public function testPrimitiveValueReadsFloatsTheSameOnEveryTarget():Void {
		function float(text:String):Float {
			var value:PrimitiveValue = text;
			return value.toFloat();
		}
		var read:Array<{text:String, value:Float}> = [
			{text: "42", value: 42.0},
			{text: " 1.5 ", value: 1.5},
			{text: "+5", value: 5.0},
			{text: "-2.5e3", value: -2500.0},
			{text: "1E3", value: 1000.0},
			{text: "2e-3", value: 0.002},
			{text: ".5", value: 0.5},
			{text: "5.", value: 5.0},
			{text: "007", value: 7.0},
			{text: "\t9\n", value: 9.0},
			{text: "0x10", value: 16.0},
			{text: "-0X1f", value: -31.0},
			{text: "0x100000000", value: 4294967296.0},
			{text: "1e400", value: Math.POSITIVE_INFINITY},
			{text: "-1e400", value: Math.NEGATIVE_INFINITY},
			{text: "Infinity", value: Math.POSITIVE_INFINITY},
			{text: "-infinity", value: Math.NEGATIVE_INFINITY},
			{text: "+INF", value: Math.POSITIVE_INFINITY}
		];
		for (one in read) {
			Assert.equals(one.value, float(one.text), '"${one.text}"');
		}
		// Not through the local function: natively its result is boxed, and
		// a boxed -0.0 is an Int 0.
		var negativeZero:PrimitiveValue = "-0";
		var zero:Float = negativeZero.toFloat();
		Assert.equals(Math.NEGATIVE_INFINITY, 1 / zero, "-0 lost its sign");
		for (bad in ["abc", "", "   ", "12abc", "1,5", "1_000", "0x", "0x1p3", "0x-1", "1e", "1e+", ".", "-", "+", "e5", "NaN", "--1", "1.2.3",
			"Infinityx", "1 2", "0b101"]) {
			Assert.isTrue(Math.isNaN(float(bad)), '"$bad" was read as ' + float(bad));
		}
	}

	/**
		An `Int` read as a `Float` adds past 2^31. On eval and neko a Float
		given an Int stayed one, and two of them added as Ints.
	**/
	public function testPrimitiveValueIntReadAsAFloatAddsPastTwoToTheThirtyOne():Void {
		var value:PrimitiveValue = 2000000000;
		var half:Float = value.toFloat();
		Assert.equals(4000000000.0, half + half);
	}

	/**
		A whole `Float` within `Int`'s range is an `Int` on every target.
		JavaScript cannot tell `1.0` from `1`, and natively and on the jvm
		`Type.typeof` answers `TInt` for it too, where eval and neko answered
		`isFloat`.
	**/
	public function testPrimitiveValueTellsIntsFromFloatsTheSameOnEveryTarget():Void {
		var whole:Array<PrimitiveValue> = [1.0, 0.0, -0.0, -2147483648.0, 2147483647.0, 42];
		for (value in whole) {
			Assert.isTrue(value.isInt(), value + " is not an Int");
			Assert.isFalse(value.isFloat(), value + " is a Float");
			Assert.isTrue(value.getValueType() == TInt, value + " is " + value.getValueType());
		}
		var fractional:Array<PrimitiveValue> = [1.5, -0.25, 2147483648.0, -2147483649.0, 1e21, Math.POSITIVE_INFINITY,
			PrimitiveValue.fromDynamic(Math.NaN)];
		for (value in fractional) {
			Assert.isFalse(value.isInt(), value + " is an Int");
			Assert.isTrue(value.isFloat(), value + " is not a Float");
			Assert.isTrue(value.getValueType() == TFloat, value + " is " + value.getValueType());
		}
		var text:PrimitiveValue = "1";
		Assert.isFalse(text.isInt());
		Assert.isFalse(text.isFloat());
	}

	/** The documentation's example, as written there. **/
	public function testPrimitiveValueDocumentedExample():Void {
		var p:PrimitiveValue = 42;
		var s:String = p; // Automatic conversion to "42"
		var b:Bool = p.toBool(); // true
		Assert.equals("42", s);
		Assert.isTrue(b);
	}

	public function testPrimitiveValueToBoolNormalizesStringsAndNumbers():Void {
		// Falsy strings (after trim + lowercase).
		Assert.isFalse((("false" : PrimitiveValue)).toBool());
		Assert.isFalse((("False" : PrimitiveValue)).toBool());
		Assert.isFalse((("FALSE" : PrimitiveValue)).toBool());
		Assert.isFalse((("0" : PrimitiveValue)).toBool());
		Assert.isFalse((("" : PrimitiveValue)).toBool());
		Assert.isFalse((("   " : PrimitiveValue)).toBool());
		Assert.isFalse(((" false " : PrimitiveValue)).toBool());

		// Truthy strings.
		Assert.isTrue((("true" : PrimitiveValue)).toBool());
		Assert.isTrue((("True" : PrimitiveValue)).toBool());
		Assert.isTrue((("1" : PrimitiveValue)).toBool());
		Assert.isTrue((("yes" : PrimitiveValue)).toBool());
		Assert.isTrue((("hello" : PrimitiveValue)).toBool());

		// Numeric and null branches.
		Assert.isFalse(((0 : PrimitiveValue)).toBool());
		Assert.isTrue(((1 : PrimitiveValue)).toBool());
		Assert.isFalse(((0.0 : PrimitiveValue)).toBool());
		Assert.isTrue(((2.5 : PrimitiveValue)).toBool());
		Assert.isFalse(((cast null : PrimitiveValue)).toBool());
	}

	public function testPrimitiveValueRejectsUnsupportedDynamicConversions():Void {
		var value:PrimitiveValue = cast { nested: true };

		Assert.raises(() -> {
			var ignored:Int = value;
		}, ArgumentError);

		Assert.raises(() -> {
			var ignored:Bool = value;
		}, ArgumentError);
	}

	public function testPrimitiveValueSupportsExplicitDynamicGateAndTypeChecks():Void {
		var stringValue = PrimitiveValue.fromDynamic("42");
		var nullValue = PrimitiveValue.fromDynamic(null);

		Assert.notNull(PrimitiveValue.tryFromDynamic(true));
		Assert.isNull(PrimitiveValue.tryFromDynamic({ nested: true }));
		Assert.isTrue(stringValue.isString());
		Assert.isFalse(stringValue.isInt());
		Assert.isTrue(nullValue.isNull());
	}

	public function testSeq32UsesWrappingOrderAcrossRollover():Void {
		var beforeWrap:Seq32 = 0xFFFFFFFF;
		var afterWrap:Seq32 = 0;
		var almostWrap:Seq32 = 0xFFFFFFFE;

		Assert.isTrue(beforeWrap < afterWrap);
		Assert.isTrue(afterWrap > beforeWrap);
		Assert.isTrue(almostWrap < afterWrap);
	}

	public function testSeq32ConvertsToUnsignedFloatAndWrapsArithmetic():Void {
		var value:Seq32 = -1;
		var asFloat:Float = value;
		var wrapped:Seq32 = value + 2;

		Assert.floatEquals(4294967295.0, asFloat);
		Assert.equals(1, (wrapped : Int));
	}

	public function testTypedObjectSupportsConstructionAndDynamicCasts():Void {
		var created:TypedObject<SamplePayload> = new TypedObject(() -> {
			return {
				id: 7,
				name: "created"
			};
		});

		var casted:TypedObject<SamplePayload> = cast {
			id: 9,
			name: "cast"
		};

		Assert.equals(7, created.id);
		Assert.equals("created", created.name);
		Assert.equals(9, casted.id);
		Assert.equals("cast", casted.name);
	}

	/**
		A `TypedObject` converts from its `T` and to it, and from and to
		nothing else. It converted from and to `Dynamic`, so a String or an
		Int compiled as a `TypedObject<{id:Int, name:String}>` (its `id`
		then null, or a cast that throws on the jvm), and one compiled as an
		`Int`. A `Dynamic`, as `Json.parse` gives, is still taken, and with
		the untyped conversion gone `for (field in typed)` compiles.
	**/
	public function testTypedObjectConvertsOnlyFromAndToItsType():Void {
		Assert.notNull(TypeCheck.errorOf({
			var typed:TypedObject<SamplePayload> = "hello";
		}), "a String became a TypedObject");
		Assert.notNull(TypeCheck.errorOf({
			var typed:TypedObject<SamplePayload> = 42;
		}), "an Int became a TypedObject");
		Assert.notNull(TypeCheck.errorOf({
			var typed:TypedObject<SamplePayload> = TypedObject.of("hello");
		}), "a TypedObject of a String became one of a structure");
		var parsed:TypedObject<SamplePayload> = haxe.Json.parse('{"id":3,"name":"p"}');
		Assert.notNull(TypeCheck.errorOf({
			var count:Int = parsed;
		}), "a TypedObject became an Int");

		Assert.equals(3, parsed.id);
		var plain:SamplePayload = parsed;
		var loose:Dynamic = parsed;
		var object:Object = parsed;
		var back:TypedObject<SamplePayload> = plain;
		Assert.equals("p", plain.name);
		Assert.equals(3, loose.id);
		Assert.equals(3, object.id);
		Assert.equals("p", back.name);
		var seen:Array<String> = [for (field in parsed) field];
		seen.sort(Reflect.compare);
		Assert.same(["id", "name"], seen);
	}

	public function testTypedObjectSupportsOfBracketAccessAndFieldIteration():Void {
		var object = TypedObject.of({
			id: 11,
			name: "typed"
		});

		Assert.equals(11, object.id);
		Assert.equals("typed", object["name"]);
		Assert.isTrue(object.exists("id"));

		var keys = object.keys();
		Assert.isTrue(keys.indexOf("id") != -1);
		Assert.isTrue(keys.indexOf("name") != -1);

		var entries = [];
		for (entry in object.entries()) {
			entries.push(entry.key + "=" + Std.string(entry.value));
		}

		Assert.isTrue(entries.indexOf("id=11") != -1);
		Assert.isTrue(entries.indexOf("name=typed") != -1);
	}
}
