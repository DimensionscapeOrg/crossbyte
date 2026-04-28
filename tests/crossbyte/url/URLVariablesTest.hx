package crossbyte.url;

import utest.Assert;

class URLVariablesTest extends utest.Test {
	public function testDecodePreservesRepeatedKeysAndSemicolonSeparators():Void {
		var variables = new URLVariables("a=1&a=2;b=three%20four;c");

		Assert.equals("1", variables["a"]);
		Assert.same(["1", "2"], variables.all("a"));
		Assert.equals("three four", variables["b"]);
		Assert.equals("", variables["c"]);
	}

	public function testDecodeClearsExistingValues():Void {
		var variables = new URLVariables("a=1");
		variables.append("a", "2");

		variables.decode("b=3");

		Assert.isNull(variables["a"]);
		Assert.same(["3"], variables.all("b"));
	}

	public function testSetReplacesFirstValueAndAppendPreservesOrder():Void {
		var variables = new URLVariables("a=1&a=2");

		variables["a"] = "zero";
		variables.append("a", "3");

		Assert.same(["zero", "2", "3"], variables.all("a"));
	}

	public function testToStringEncodesRepeatedKeys():Void {
		var variables = new URLVariables();
		variables.append("space key", "a b");
		variables.append("space key", "c+d");

		var encoded = variables.toString();

		Assert.isTrue(encoded.indexOf("space%20key=a%20b") >= 0);
		Assert.isTrue(encoded.indexOf("space%20key=c%2Bd") >= 0);
	}
}
