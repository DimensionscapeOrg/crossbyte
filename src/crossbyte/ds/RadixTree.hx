package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A Radix Tree (Prefix Tree) implementation in Haxe.
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

		insertInto(root, key, value);
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
		return searchIn(root, key);
	}

	private function insertInto(node:RadixTreeNode<T>, key:String, value:T):Void {
		if (key.length == 0) {
			node.value = value;
			return;
		}

		var child = findMatchingChild(node, key);
		if (child == null) {
			node.children.set(key, new RadixTreeNode<T>(key, value));
			return;
		}

		var commonPrefix = getCommonPrefix(child.label, key);
		if (commonPrefix == child.label) {
			insertInto(child, key.substr(commonPrefix.length), value);
			return;
		}

		var childRemainder = child.label.substr(commonPrefix.length);
		var keyRemainder = key.substr(commonPrefix.length);
		var split = new RadixTreeNode<T>(commonPrefix);

		node.children.remove(child.label);
		child.label = childRemainder;
		split.children.set(child.label, child);

		if (keyRemainder.length == 0) {
			split.value = value;
		} else {
			split.children.set(keyRemainder, new RadixTreeNode<T>(keyRemainder, value));
		}

		node.children.set(split.label, split);
	}

	private function searchIn(node:RadixTreeNode<T>, key:String):Null<T> {
		if (key.length == 0) {
			return node.value;
		}

		var child = findMatchingChild(node, key);
		if (child == null) {
			return null;
		}

		var commonPrefix = getCommonPrefix(child.label, key);
		if (commonPrefix != child.label) {
			return null;
		}

		return searchIn(child, key.substr(commonPrefix.length));
	}

	private function findMatchingChild(node:RadixTreeNode<T>, key:String):RadixTreeNode<T> {
		for (child in node.children) {
			if (getCommonPrefix(child.label, key).length > 0) {
				return child;
			}
		}

		return null;
	}

	/**
	 * Computes the common prefix of two strings.
	 *
	 * @param str1 The first string.
	 * @param str2 The second string.
	 * @return The common prefix of the two strings.
	 */
	private function getCommonPrefix(str1:String, str2:String):String {
		var minLength:Int = Std.int(Math.min(str1.length, str2.length));
		var prefix = "";
		for (i in 0...minLength) {
			if (str1.charAt(i) != str2.charAt(i)) {
				break;
			}
			prefix += str1.charAt(i);
		}
		return prefix;
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
	public var children:Map<String, RadixTreeNode<T>>;

	/**
	 * Constructs a new Node.
	 *
	 * @param label The label of the node.
	 * @param value The value to be associated with the node (default is null).
	 */
	public function new(label:String, value:Null<T> = null) {
		this.label = label;
		this.value = value;
		this.children = new Map<String, RadixTreeNode<T>>();
	}
}
