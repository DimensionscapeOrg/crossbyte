package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A weighted graph implementation in Haxe.
 *
 * @param T The type of values stored in the graph nodes.
 */
class WeightedGraph<T> {
	private var adjacencyList:Array<Adjacency<T>>;

	/**
	 * Constructs a new WeightedGraph.
	 */
	public function new() {
		adjacencyList = [];
	}

	/**
	 * Adds a node to the graph.
	 *
	 * @param node The node to be added.
	 */
	public function addNode(node:T):Void {
		if (__find(node) == null) {
			adjacencyList.push(new Adjacency<T>(node));
		}
	}

	/**
	 * Adds a directed, weighted edge to the graph.
	 *
	 * @param from The starting node of the edge.
	 * @param to The ending node of the edge.
	 * @param weight The weight of the edge.
	 */
	public function addEdge(from:T, to:T, weight:Float):Void {
		var entry = __find(from);
		if (entry == null) {
			entry = new Adjacency<T>(from);
			adjacencyList.push(entry);
		}

		if (__find(to) == null)
			adjacencyList.push(new Adjacency<T>(to));

		entry.edges.push(new Edge<T>(to, weight));
	}

	/**
	 * Gets the neighbors and edge weights for a given node.
	 *
	 * @param node The node whose neighbors are to be retrieved.
	 * @return An array of edges representing the neighbors and their weights.
	 */
	public function getNeighbors(node:T):Array<Edge<T>> {
		var entry = __find(node);
		return entry == null ? null : entry.edges;
	}

	private function __find(node:T):Adjacency<T> {
		for (entry in adjacencyList) {
			if (entry.node == node)
				return entry;
		}

		return null;
	}
}

private class Adjacency<T> {
	public var node:T;
	public var edges:Array<Edge<T>>;

	public function new(node:T) {
		this.node = node;
		this.edges = [];
	}
}

/**
 * Edge class representing an edge in the weighted graph.
 *
 * @param T The type of the node.
 */
private class Edge<T> {
	public var to:T;
	public var weight:Float;

	/**
	 * Constructs a new Edge.
	 *
	 * @param to The ending node of the edge.
	 * @param weight The weight of the edge.
	 */
	public function new(to:T, weight:Float) {
		this.to = to;
		this.weight = weight;
	}
}
