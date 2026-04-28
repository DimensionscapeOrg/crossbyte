package crossbyte.foundation;

import crossbyte.FieldStruct;
import crossbyte.Object;
import crossbyte.PrimitiveValue;
import crossbyte.Seq32;
import crossbyte.TypedObject;
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

	public function testPrimitiveValueRejectsUnsupportedDynamicConversions():Void {
		var value:PrimitiveValue = cast { nested: true };

		Assert.raises(() -> {
			var ignored:Int = value;
		});

		Assert.raises(() -> {
			var ignored:Bool = value;
		});
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
