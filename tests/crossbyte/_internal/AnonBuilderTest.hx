package crossbyte._internal;

import utest.Assert;

/**
	`AnonBuilder`: objects of one shape, with fixed slots on hxcpp, that read
	back every field by name as an object made with `Reflect.setField` does.

	The shapes are wide on purpose. hxcpp checks the first five slots one by
	one and binary-searches the rest by the signed hash of the name; ordered
	by the unsigned hash, a name whose hash has its top bit set sorts after
	the others and the search past the fifth slot misses it, so the field
	reads as absent. Forty names make several of each kind certain.
**/
class AnonBuilderTest extends utest.Test {
	static final NAMES:Array<String> = [for (i in 0...40) "field_" + i + "_" + StringTools.hex((i * 40503) & 0xFFFF)];

	public function testEveryFieldOfAWideShapeReadsBack():Void {
		var builder:AnonBuilder = new AnonBuilder(NAMES);
		#if cpp
		Assert.isTrue(builder.fixed, "a shape of distinct ASCII names takes fixed slots");
		#end

		for (round in 0...3) {
			var object:Dynamic = builder.begin();

			for (i in 0...NAMES.length) {
				builder.setInt(object, i, i * 10 + round);
			}

			var missing:Array<String> = [];

			for (i in 0...NAMES.length) {
				var value:Dynamic = Reflect.field(object, NAMES[i]);

				if (value != i * 10 + round || !Reflect.hasField(object, NAMES[i])) {
					missing.push(NAMES[i] + "=" + Std.string(value));
				}
			}

			Assert.equals(0, missing.length, "fields that did not read back: " + missing.join(", "));
			Assert.equals(NAMES.length, Reflect.fields(object).length);
		}
	}

	public function testTypedSettersKeepTheirValues():Void {
		var builder:AnonBuilder = new AnonBuilder(["id", "name", "score", "active", "tags", "missing", "seventh"]);
		var object:Dynamic = builder.begin();
		builder.setInt(object, 0, 7);
		builder.setString(object, 1, "user 7");
		builder.setFloat(object, 2, 12.5);
		builder.setBool(object, 3, true);
		builder.set(object, 4, ["a", "b"]);
		builder.set(object, 5, null);
		builder.setInt(object, 6, -1);

		var id:Int = object.id;
		var name:String = object.name;
		var score:Float = object.score;
		var active:Bool = object.active;
		var tags:Array<String> = object.tags;
		Assert.equals(7, id);
		Assert.equals("user 7", name);
		Assert.equals(12.5, score);
		Assert.isTrue(active);
		Assert.equals("a,b", tags.join(","));
		Assert.isNull(object.missing);
		Assert.isTrue(Reflect.hasField(object, "missing"), "a field set to null is there, holding null");
		Assert.equals(-1, object.seventh);
		Assert.isTrue(Std.isOfType(object.id, Int));
		Assert.isTrue(Std.isOfType(object.score, Float));
		Assert.isTrue(Std.isOfType(object.active, Bool));
	}

	public function testAFieldAddedLaterAndAWriteToASlotBothHold():Void {
		var builder:AnonBuilder = new AnonBuilder(NAMES);
		var object:Dynamic = builder.begin();

		for (i in 0...NAMES.length) {
			builder.setInt(object, i, i);
		}

		Reflect.setField(object, "extra", "added");
		Reflect.setField(object, NAMES[33], "replaced");
		Assert.equals("added", Reflect.field(object, "extra"));
		Assert.equals("replaced", Reflect.field(object, NAMES[33]));
		Assert.equals(NAMES.length + 1, Reflect.fields(object).length);
		Assert.isTrue(Reflect.deleteField(object, NAMES[20]));
		Assert.isFalse(Reflect.hasField(object, NAMES[20]));
		Assert.equals(21, Reflect.field(object, NAMES[21]));
	}

	public function testRepeatedNamesKeepTheLastValue():Void {
		var builder:AnonBuilder = new AnonBuilder(["a", "b", "a"]);
		Assert.isFalse(builder.fixed, "a repeated name cannot take a slot of its own");
		var object:Dynamic = builder.begin();
		builder.setInt(object, 0, 1);
		builder.setInt(object, 1, 2);
		builder.setInt(object, 2, 3);
		Assert.equals(3, object.a);
		Assert.equals(2, object.b);
		Assert.equals(2, Reflect.fields(object).length);
	}

	public function testNamesThatAreNotAsciiStillReadBack():Void {
		var names:Array<String> = ["plain", "café", "日本", "x"];
		var builder:AnonBuilder = new AnonBuilder(names);
		var object:Dynamic = builder.begin();

		for (i in 0...names.length) {
			builder.setInt(object, i, i + 1);
		}

		for (i in 0...names.length) {
			Assert.equals(i + 1, Reflect.field(object, names[i]), names[i]);
		}
	}

	public function testMatchesComparesTheLeadingNames():Void {
		var builder:AnonBuilder = new AnonBuilder(["a", "b"]);
		Assert.isTrue(builder.matches(["a", "b", "c"], 2));
		Assert.isFalse(builder.matches(["a", "c"], 2));
		Assert.isFalse(builder.matches(["a", "b", "c"], 3));
	}

	public function testTheShapeIsCopiedFromTheNamesGiven():Void {
		var names:Array<String> = ["one", "two"];
		var builder:AnonBuilder = new AnonBuilder(names);
		names[0] = "changed";
		var object:Dynamic = builder.begin();
		builder.setInt(object, 0, 1);
		builder.setInt(object, 1, 2);
		Assert.equals(1, object.one);
		Assert.isFalse(Reflect.hasField(object, "changed"));
	}
}
