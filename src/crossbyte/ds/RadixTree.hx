package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A Radix Tree (Prefix Tree) implementation in Haxe.
 *
 * `search` finds a key exactly; `longestPrefix` finds the longest key held
 * that the one given starts with: the route that serves
 * "/api/v1/users/123" when "/api/v1/users" is held.
 *
 * A lookup reads the key in place and allocates nothing.
 *
 * ```haxe
 * var routes = new RadixTree<Handler>();
 * routes.insert("/api/v1/users", users);
 * routes.insert("/api/v1/rooms", rooms);
 * var handler = routes.longestPrefix(path); // users, for "/api/v1/users/123"
 * ```
 *
 * @param T The type of values to be stored in the tree.
 */
class RadixTree<T> {
	private var root:RadixTreeNode<T>;

	/**
	 * Constructs a new RadixTree.
	 */
	public function new() {
		root = new RadixTreeNode<T>("");
	}

	/**
	 * Inserts a key-value pair into the Radix Tree.
	 *
	 * @param key The key to be inserted.
	 * @param value The value to be associated with the key.
	 */
	public function insert(key:String, value:T):Void {
		// Handle empty or null key
		if (key == null || key.length == 0)
			return;

		var node:RadixTreeNode<T> = root;
		var at:Int = 0;
		while (true) {
			if (at == key.length) {
				node.value = value;
				node.hasValue = true;
				return;
			}

			var child:RadixTreeNode<T> = node.childFor(StringTools.fastCodeAt(key, at));
			if (child == null) {
				node.children.push(new RadixTreeNode<T>(key.substr(at), value, true));
				return;
			}

			var label:String = child.label;
			var common:Int = __matching(label, key, at);
			if (common == label.length) {
				node = child;
				at += common;
				continue;
			}

			// The key parts from the child's label part way along it: the
			// shared part becomes a node of its own above the child.
			var split:RadixTreeNode<T> = new RadixTreeNode<T>(label.substr(0, common));
			child.label = label.substr(common);
			split.children.push(child);
			node.children[node.children.indexOf(child)] = split;
			at += common;
			if (at == key.length) {
				split.value = value;
				split.hasValue = true;
			} else {
				split.children.push(new RadixTreeNode<T>(key.substr(at), value, true));
			}
			return;
		}
	}

	/**
	 * Searches for a key in the Radix Tree and returns the associated value.
	 *
	 * @param key The key to be searched.
	 * @return The value associated with the key, or null if the key is not found.
	 */
	public function search(key:String):Null<T> {
		// Handle empty or null key
		if (key == null || key.length == 0)
			return null;

		var node:RadixTreeNode<T> = root;
		var at:Int = 0;
		while (at < key.length) {
			node = __step(node, key, at);
			if (node == null) {
				return null;
			}
			at += node.label.length;
		}
		return node.hasValue ? node.value : null;
	}

	/**
	 * The value of the longest key held that `key` starts with, or null when
	 * none is held. A key is its own longest prefix.
	 */
	public function longestPrefix(key:String):Null<T> {
		var found:RadixTreeNode<T> = __longest(key);
		return found == null ? null : found.value;
	}

	/**
	 * The length of the longest key held that `key` starts with, or -1 when
	 * none is held: what is left of `key` after it is `key.substr(length)`.
	 */
	public function longestPrefixLength(key:String):Int {
		if (key == null) {
			return -1;
		}
		var node:RadixTreeNode<T> = root;
		var at:Int = 0;
		var best:Int = -1;
		while (at < key.length) {
			node = __step(node, key, at);
			if (node == null) {
				break;
			}
			at += node.label.length;
			if (node.hasValue) {
				best = at;
			}
		}
		return best;
	}

	private function __longest(key:String):Null<RadixTreeNode<T>> {
		if (key == null) {
			return null;
		}
		var node:RadixTreeNode<T> = root;
		var at:Int = 0;
		var best:RadixTreeNode<T> = null;
		while (at < key.length) {
			node = __step(node, key, at);
			if (node == null) {
				break;
			}
			at += node.label.length;
			if (node.hasValue) {
				best = node;
			}
		}
		return best;
	}

	// The child of `node` whose whole label `key` holds at `at`, or null.
	private static function __step<T>(node:RadixTreeNode<T>, key:String, at:Int):Null<RadixTreeNode<T>> {
		var child:RadixTreeNode<T> = node.childFor(StringTools.fastCodeAt(key, at));
		if (child == null) {
			return null;
		}
		var label:String = child.label;
		if (key.length - at < label.length || __matching(label, key, at) != label.length) {
			return null;
		}
		return child;
	}

	// How many characters from the start of `label` match `key` from `at`.
	private static function __matching(label:String, key:String, at:Int):Int {
		var most:Int = key.length - at;
		if (label.length < most) {
			most = label.length;
		}
		var i:Int = 0;
		while (i < most && StringTools.fastCodeAt(label, i) == StringTools.fastCodeAt(key, at + i)) {
			i++;
		}
		return i;
	}
}

/**
 * Represents a node in the Radix Tree.
 *
 * @param T The type of values to be stored in the tree.
 */
@:private
@:noCompletion
class RadixTreeNode<T> {
	public var label:String;
	public var value:Null<T>;
	// Whether a key ends here, apart from whether its value is null.
	public var hasValue:Bool;
	// No two begin with the same character, so the one to follow is found by
	// its first; a node has few, so a pass beats a hash.
	public var children:Array<RadixTreeNode<T>>;

	/**
	 * Constructs a new Node.
	 *
	 * @param label The label of the node.
	 * @param value The value to be associated with the node (default is null).
	 */
	public function new(label:String, value:Null<T> = null, hasValue:Bool = false) {
		this.label = label;
		this.value = value;
		this.hasValue = hasValue;
		this.children = [];
	}

	public function childFor(code:Int):Null<RadixTreeNode<T>> {
		for (child in children) {
			if (StringTools.fastCodeAt(child.label, 0) == code) {
				return child;
			}
		}
		return null;
	}
}
