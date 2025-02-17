package crossbyte.ds;

import haxe.ds.IntMap;

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
	private var adjacencyList:Map<T, Array<Edge<T>>>;

	/**
	 * Constructs a new WeightedGraph.
	 */
	public function new() {
		adjacencyList = new Map<T, Array<Edge<T>>>();
	}

	/**
	 * Adds a node to the graph.
	 *
	 * @param node The node to be added.
	 */
	public function addNode(node:T):Void {
		if (!adjacencyList.exists(node)) {
			adjacencyList.set(node, []);
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
		if (!adjacencyList.exists(from))
			addNode(from);
		if (!adjacencyList.exists(to))
			addNode(to);
		adjacencyList.get(from).push(new Edge<T>(to, weight));
	}

	/**
	 * Gets the neighbors and edge weights for a given node.
	 *
	 * @param node The node whose neighbors are to be retrieved.
	 * @return An array of edges representing the neighbors and their weights.
	 */
	public function getNeighbors(node:T):Array<Edge<T>> {
		return adjacencyList.get(node);
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
