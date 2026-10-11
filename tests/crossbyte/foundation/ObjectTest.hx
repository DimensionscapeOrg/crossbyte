package crossbyte.foundation;

import crossbyte.Object;
import utest.Assert;

/**
	`Object` used as an ActionScript or JavaScript programmer uses one, and
	answering the same on every target.
**/
class ObjectTest extends utest.Test {
	/**
		ActionScript's `Object` methods answer the same on every target.
		Called through the object's own fields, as they were, they answered
		only on JavaScript, where every object's prototype has them, and threw
		on every other target (natively, on a null `Object`, the process
		ended).
	**/
	public function testActionScriptsMethodsAnswerTheSameEverywhere():Void {
		var payload:Object = haxe.Json.parse('{"a":1,"b":null}');
		Assert.isTrue(payload.hasOwnProperty("a"));
		Assert.isTrue(payload.hasOwnProperty("b"), "a field holding null is the object's own");
		Assert.isFalse(payload.hasOwnProperty("c"));
		Assert.isFalse(payload.hasOwnProperty("toString"), "a prototype's method was taken for a field");
		Assert.isTrue(payload.propertyIsEnumerable("a"));
		Assert.isFalse(payload.propertyIsEnumerable("c"));
		Assert.isFalse(payload.isPrototypeOf({}));
		Assert.isTrue(payload.valueOf() == payload);
		var number:Object = 3;
		Assert.equals("3", number.toString());
		Assert.equals("3", number.toLocaleString());
		var text:Object = "x";
		Assert.equals("x", text.toString());
		Assert.isTrue(number.valueOf() == 3);

		var instance:Object = new Sealed();
		Assert.isFalse(instance.propertyIsEnumerable("field"), "a class instance's field was enumerable");
		Assert.isFalse(instance.isPrototypeOf(new Sealed()));
	}

	/** The same of a null `Object`: no fields, and `"null"` as text. **/
	public function testActionScriptsMethodsOfANullObject():Void {
		var nothing:Object = null;
		Assert.isFalse(nothing.hasOwnProperty("a"));
		Assert.isFalse(nothing.propertyIsEnumerable("a"));
		Assert.isFalse(nothing.isPrototypeOf({}));
		Assert.isNull(nothing.valueOf());
		Assert.equals("null", nothing.toString());
	}
}

private class Sealed {
	public var field:Int = 1;

	public function new() {}
}
