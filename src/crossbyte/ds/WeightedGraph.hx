package crossbyte.ds;

import haxe.ds.IntMap;
import haxe.ds.ObjectMap;
import haxe.ds.StringMap;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A weighted graph implementation in Haxe.
 *
 * Nodes are found by hashing, as `==` tells them apart: strings and
 * integers by value, objects by identity, so building a graph of n nodes
 * costs n lookups rather than n^2 comparisons. Floats, booleans and null,
 * which few graphs use as nodes, are found by a pass over the nodes of
 * that kind. On the interpreter its own `ObjectMap` is not a hash, and
 * object nodes cost n^2 there.
 *
 * NaN is refused as a node with an `ArgumentError`: it equals nothing, not
 * even itself, so every use of it added another node nobody could reach.
 *
 * @param T The type of values stored in the graph nodes.
 */
class WeightedGraph<T> {
	private var adjacencyList:Array<Adjacency<T>>;

	private var __byString:StringMap<Adjacency<T>>;
	private var __byInt:IntMap<Adjacency<T>>;
	private var __byObject:ObjectMap<Dynamic, Adjacency<T>>;
	private var __others:Array<Adjacency<T>>;

	/**
	 * Constructs a new WeightedGraph.
	 */
	public function new() {
		adjacencyList = [];
		__byString = new StringMap();
		__byInt = new IntMap();
		__byObject = new ObjectMap();
		__others = [];
	}

	/**
	 * Adds a node to the graph.
	 *
	 * @param node The node to be added.
	 */
	public function addNode(node:T):Void {
		if (__find(node) == null) {
			__add(node);
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
			entry = __add(from);
		}

		if (__find(to) == null)
			__add(to);

		entry.edges.push(new Edge<T>(to, weight));
	}

	/**
	 * Gets the neighbors and edge weights for a given node.
	 *
	 * @param node The node whose neighbors are to be retrieved.
	 * @return An array of edges representing the neighbors and their weights:
	 *         the node's own, to read; adding to it adds no node.
	 */
	public function getNeighbors(node:T):Array<Edge<T>> {
		var entry = __find(node);
		return entry == null ? null : entry.edges;
	}

	private function __add(node:T):Adjacency<T> {
		var key:Dynamic = node;
		if (Std.isOfType(key, Float) && Math.isNaN(key)) {
			throw new crossbyte.errors.ArgumentError("NaN cannot be a node: it equals no node, not even itself.");
		}
		var entry = new Adjacency<T>(node);
		adjacencyList.push(entry);
		switch (__kind(key)) {
			case 0:
				__byString.set(key, entry);
			case 1:
				__byInt.set(key, entry);
			case 2:
				__byObject.set(key, entry);
			default:
				__others.push(entry);
		}
		return entry;
	}

	private function __find(node:T):Adjacency<T> {
		var key:Dynamic = node;
		switch (__kind(key)) {
			case 0:
				return __byString.get(key);
			case 1:
				return __byInt.get(key);
			case 2:
				return __byObject.get(key);
			default:
				for (entry in __others) {
					if (entry.node == node)
						return entry;
				}
				return null;
		}
	}

	// 0 a string, 1 an integer, 2 an object (an instance, a structure, an
	// enum value, a function), 3 anything else.
	private static function __kind(key:Dynamic):Int {
		if (key == null) {
			return 3;
		}
		if (Std.isOfType(key, String)) {
			return 0;
		}
		if (Std.isOfType(key, Int)) {
			// The jvm's IntMap visits every bucket to find a missing key, and
			// every new node is one; its ObjectMap compares a boxed Integer by
			// value, and stops at the first empty bucket.
			return #if (java || jvm) 2 #else 1 #end;
		}
		if (Std.isOfType(key, Float) || Std.isOfType(key, Bool)) {
			return 3;
		}
		return 2;
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
 * An edge of a `WeightedGraph`: the node it leads to, and its weight; what
 * `getNeighbors` answers.
 *
 * @param T The type of the node.
 */
class Edge<T> {
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
