package crossbyte.ds;

import utest.Assert;

class CollectionsTest extends utest.Test {
	public function testBloomFilterFindsAddedItems():Void {
		var filter = new BloomFilter(128, 3);

		Assert.isFalse(filter.contains("alpha"));
		filter.add("alpha");
		Assert.isTrue(filter.contains("alpha"));
	}

	public function testVectorSpliceReturnsRemovedAndKeepsInsertOrder():Void {
		var vector = new Vector<String>();
		vector.push("a");
		vector.push("b");
		vector.push("c");

		var removed = vector.splice(1, 1, "x", "y");

		Assert.equals("b", removed.join(","));
		Assert.equals("a,x,y,c", vector.join(","));
	}

	public function testWeightedGraphSupportsStringNodes():Void {
		var graph = new WeightedGraph<String>();
		graph.addEdge("a", "b", 2.5);

		var neighbors:Array<Dynamic> = cast graph.getNeighbors("a");
		Assert.equals(1, neighbors.length);
		Assert.equals("b", Reflect.field(neighbors[0], "to"));
		Assert.equals(2.5, Reflect.field(neighbors[0], "weight"));
		Assert.notNull(graph.getNeighbors("b"));
		Assert.isNull(graph.getNeighbors("missing"));
	}

	public function testWeightedGraphSupportsObjectNodes():Void {
		var from = {id: 1};
		var to = {id: 2};
		var graph = new WeightedGraph<Dynamic>();

		graph.addEdge(from, to, 7);

		var neighbors:Array<Dynamic> = cast graph.getNeighbors(from);
		Assert.equals(to, Reflect.field(neighbors[0], "to"));
		Assert.isNull(graph.getNeighbors({id: 1}));
	}
}
