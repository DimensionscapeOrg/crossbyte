package crossbyte.ds;

import crossbyte.ds.ListedMap.KeyValuePair;
import crossbyte.ds.WeightedGraph.Edge;
import crossbyte.utils.EnumUtil;
import utest.Assert;

private enum Shape {
	Dot;
	Box(width:Int, height:Int);
}

/**
	The typed shapes for what would otherwise be anonymous structures,
	`Dynamic` and `Function`: classes built from the same literals,
	callbacks of known arity called directly, and a dispatcher that looks
	typed keys up typed. Each case names the type, or checks what it holds.
**/
class TypedShapesTest extends utest.Test {
	public function testAPairIsAClassBuiltFromALiteral():Void {
		var map = new ListedMap<String, Int>();
		map.set("a", 1);
		var pair = map.keyValuePairs[0];
		Assert.isTrue(Std.isOfType(pair, KeyValuePair), "a ListedMap pair is not a KeyValuePair");

		// A literal still makes one, and one still fits a {key, value}.
		var literal:KeyValuePair<String, Int> = {key: "b", value: 2};
		var structural:{key:String, value:Int} = literal;
		Assert.equals("b", structural.key);
		Assert.equals(2, structural.value);

		var ordered = new OrderedMap<String, Int>();
		ordered.set("x", 7);
		for (entry in ordered.keyValuePairs()) {
			Assert.isTrue(Std.isOfType(entry, KeyValuePair), "an OrderedMap pair is not a KeyValuePair");
			Assert.equals("x", entry.key);
			Assert.equals(7, entry.value);
		}
	}

	public function testEnumUtilAnswersTypedValues():Void {
		var params:Array<Dynamic> = EnumUtil.getValue(Dot);
		Assert.equals(0, params.length, "a constructor without parameters did not answer an empty array");
		Assert.equals("Box", EnumUtil.getValueName(Box(2, 3)));
		var pair = EnumUtil.getNameValuePair(Box(2, 3));
		Assert.isTrue(Std.isOfType(pair, crossbyte.utils.EnumUtil.EnumNameValue));
		Assert.equals("Box", pair.name);
		Assert.equals(3, pair.value[1]);
	}

	public function testAGraphsEdgesCanBeNamed():Void {
		var graph = new WeightedGraph<Int>();
		graph.addEdge(1, 2, 0.5);
		var edges:Array<Edge<Int>> = graph.getNeighbors(1);
		Assert.equals(2, edges[0].to);
		Assert.equals(0.5, edges[0].weight);
	}

	/** Every arity a callback may have, typed, untyped and Dynamic. **/
	public function testVectorCallbacksOfEveryArity():Void {
		var vector = new Vector<Int>();
		for (i in 0...4) {
			vector.push(i);
		}

		var seen:Array<String> = [];
		vector.forEach(function():Void seen.push("-"));
		vector.forEach((v:Int) -> seen.push("" + v));
		vector.forEach((v:Int, i:Int) -> seen.push(v + "@" + i));
		vector.forEach((v:Int, i:Int, of:Vector<Int>) -> seen.push("" + of.length));
		Assert.equals("-,-,-,-,0,1,2,3,0@0,1@1,2@2,3@3,4,4,4,4", seen.join(","));

		Assert.isTrue(vector.every((v:Int) -> v < 4));
		Assert.isFalse(vector.every((v:Int, i:Int) -> v < 2));
		Assert.isTrue(vector.some((v:Int) -> v == 3));
		Assert.equals("0,2", vector.filter((v:Int) -> v % 2 == 0).join(","));
		Assert.equals("0,2,4,6", vector.map((v:Int) -> v * 2).join(","));

		var loose:crossbyte.Function = (v:Int, i:Int) -> v + i;
		Assert.equals("0,2,4,6", vector.map(loose).join(","));
		var anything:Dynamic = (v:Int) -> v > 0;
		Assert.equals("1,2,3", vector.filter(anything).join(","));
	}

	/**
		`map` gives a vector of what its callback returns. It was typed as
		the vector's own element type whatever the callback gave, so an `Int`
		vector mapped to text claimed to be a `Vector<Int>` holding strings,
		which a static target reads back as numbers it is not.
	**/
	public function testVectorMapIsTypedByWhatItsCallbackReturns():Void {
		var vector = new Vector<Int>();
		vector.push(1);
		vector.push(2);

		Assert.equals("crossbyte.ds.Vector<String>", TypeCheck.typeOf(vector.map((v:Int) -> "n" + v)));
		Assert.equals("crossbyte.ds.Vector<Int>", TypeCheck.typeOf(vector.map((v:Int, i:Int) -> v + i)));
		Assert.notNull(TypeCheck.errorOf({
			var wrong:Vector<Int> = vector.map((v:Int) -> "n" + v);
		}), "text mapped from numbers was taken as a vector of numbers");

		var named:Vector<String> = vector.map((v:Int) -> "n" + v);
		Assert.equals("n1,n2", named.join(","));
	}

	public function testVectorSortAndConcatAreTyped():Void {
		var vector = new Vector<Int>();
		vector.push(3);
		vector.push(1);
		vector.push(2);
		Assert.equals("3,2,1", vector.sort((a, b) -> b - a).join(","));
		Assert.equals("1,2,3", vector.sort().join(","));

		var other = new Vector<Int>();
		other.push(9);
		Assert.equals("1,2,3,9", vector.concat(other).join(","));
		Assert.notNull(TypeCheck.errorOf(vector.concat([4, 5])), "an Array was taken where a Vector is asked for");
		Assert.notNull(TypeCheck.errorOf(vector.sort(42)), "a number was taken as a comparator");
	}

	/**
		Keys named by constants from another class are their values: a
		dispatch with the value finds the case, and one with a value no case
		names reaches the fallback with it.
	**/
	public function testASwitchTableKeyedOnNamedConstantsMatchesTheirValues():Void {
		var hits:Array<String> = [];
		var named = SwitchTable.make([
			{key: TypedShapesOpcodes.LOGIN, handler: () -> hits.push("login")},
			{key: TypedShapesOpcodes.LOGOUT, handler: () -> hits.push("logout")}
		], (key:Int) -> hits.push("other " + key));
		named(TypedShapesOpcodes.LOGOUT);
		named(10);
		named(99);
		Assert.equals("logout,login,other 99", hits.join(","));
	}

	public function testAnObjectsEntriesAndValues():Void {
		var bag:crossbyte.Object = {a: 1};
		var entries = [for (entry in bag.entries()) entry];
		Assert.equals(1, entries.length);
		Assert.isTrue(Std.isOfType(entries[0], KeyValuePair));
		Assert.equals("a", entries[0].key);
		Assert.equals(1, entries[0].value);
		Assert.equals(1, bag.values()[0]);
	}
}

class TypedShapesOpcodes {
	public static inline var LOGIN:Int = 10;
	public static inline var LOGOUT:Int = 11;
}
