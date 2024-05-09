package crossbyte._internal.deflatex;

import haxe.ds.BalancedTree;
import haxe.Exception;
import haxe.ds.Vector;
import crossbyte._internal.deflatex.utils.PriorityQueue;
import crossbyte._internal.deflatex.utils.IComparable;

/**
 * Implements a Huffman tree.
 */
class HuffmanTree {
	private var numSymbols:Int;
	private var depthMap:BalancedTree<Int, Array<LeafNode>>;
	private var maxDepth:Int;
	private var root:Node;

	/**
	 * Construct a Huffman tree from the given frequencies.
	 * @param freq The symbol frequencies
	 * @param limit The depth limit
	 */
	public function new(freq:Vector<Int>, limit:Int) {
		numSymbols = freq.length;
		depthMap = new BalancedTree<Int, Array<LeafNode>>();
		maxDepth = 0;

		var queue:PriorityQueue<Node> = new PriorityQueue<Node>();
		for (i in 0...numSymbols) {
			if (freq[i] > 0) {
				queue.add(new LeafNode(i, freq[i]));
			}
		}

		var index:Int = 0;
		while (queue.length < 2) {
			if (freq[index] == 0) {
				queue.add(new LeafNode(index, 1));
			}
			index++;
		}

		var n:UInt = queue.length;
		for (i in 0...n - 1) {
			var left:Node = queue.remove();
			var right:Node = queue.remove();
			queue.add(new InternalNode(left, right));
		}
		root = queue.remove();

		traverse(root);

		while (maxDepth > limit) {
			var leafA:LeafNode = depthMap.get(maxDepth)[0];

			var parent1:InternalNode = cast(leafA.parent);
			var leafB:LeafNode;
			if (leafA.side == 0) {
				leafB = cast(parent1.right);
			} else {
				leafB = cast(parent1.left);
			}

			var parent2:InternalNode = cast(parent1.parent);
			if (parent1.side == 0) { // removing the current leaf
				parent2.left = leafB;
				parent2.left.parent = parent2;
				parent2.left.side = 0;
			} else {
				parent2.right = leafB;
				parent2.right.parent = parent2;
				parent2.right.side = 1;
			}

			var moved:Bool = false;
			var i:Int = maxDepth - 2;
			while (i > 0) {
				var leaves:Array<LeafNode> = depthMap.get(i);
				if (leaves != null) {
					var leafC:LeafNode = leaves[0];

					var parent3:InternalNode = cast(leafC.parent);
					if (leafC.side == 0) {
						parent3.left = new InternalNode(leafA, leafC);
						parent3.left.parent = parent3;
						parent3.left.side = 0;
					} else {
						parent3.right = new InternalNode(leafA, leafC);
						parent3.right.parent = parent3;
						parent3.right.side = 1;
					}

					moved = true;
					break;
				}
				i--;
			}
			if (!moved) {
				throw new Exception("Can't balance the tree");
			}

			traverse(root);
		}
	}

	private function traverse(root:Node) {
		depthMap.clear();
		maxDepth = 0;
		traverseTo(root, 0);
	}

	private function traverseTo(node:Node, depth:Int) {
		if (depth > maxDepth)
			maxDepth = depth;

		if (Std.isOfType(node, InternalNode)) {
			traverseTo(cast(node, InternalNode).left, depth + 1);
			traverseTo(cast(node, InternalNode).right, depth + 1);
		} else if (Std.isOfType(node, LeafNode)) {
			if (depthMap.get(depth) == null) {
				depthMap.set(depth, new Array<LeafNode>());
			}
			depthMap.get(depth).push(cast(node));
		}
	}

	/**
	 * Convert the current tree into a table of canonical codes.
	 * @return A Huffman table of the current tree
	 */
	public function getTable():HuffmanTable {
		var table:HuffmanTable = new HuffmanTable(numSymbols);
		var code:Vector<Int> = table.code;
		var codelen:Vector<Int> = table.codeLen;

		var nextCode:Int = 0;
		var lastShift:Int = 0;
		for (length in depthMap.keys()) {
			nextCode <<= (length - lastShift);
			lastShift = length;

			var leaves:Array<LeafNode> = depthMap.get(length);
			leaves.sort((n1:LeafNode, n2:LeafNode) -> {
				return n1.value - n2.value;
			});

			for (leaf in leaves) {
				code[leaf.value] = nextCode++;
				codelen[leaf.value] = length;
			}
		}

		return table;
	}
}

private class Node implements IComparable<Node> {
	public var parent:Node;
	public var side:Int;
	public var weight:Int;

	public function compareTo(node:Node):Int {
		return weight - node.weight;
	}
}

private class InternalNode extends Node {
	public var left:Node;
	public var right:Node;

	public function new(left:Node, right:Node) {
		left.parent = this;
		left.side = 0;
		this.left = left;

		right.parent = this;
		right.side = 1;
		this.right = right;

		weight = left.weight + right.weight;
	}

	@:keep
	public function toString():String {
		return "[" + Std.string(left) + ", " + Std.string(right) + "]";
	}
}

private class LeafNode extends Node {
	public var value:Int;

	public function new(value:Int, weight:Int) {
		this.value = value;
		this.weight = weight;
	}

	@:keep
	public function toString():String {
		return Std.string(value);
	}
}
