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
	private var root:Node<T>;

	/**
	 * Constructs a new RadixTree.
	 */
	public function new() {
		root = new Node<T>("");
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

		var currentNode = root;
		var currentKey = key;

		while (true) {
			var commonPrefix = getCommonPrefix(currentNode.label, currentKey);

			if (commonPrefix.length == 0) {
				var newNode = new Node<T>(currentKey, value);
				currentNode.children.set(currentKey, newNode);
				return;
			}

			if (commonPrefix == currentNode.label) {
				var remainingKey = currentKey.substr(commonPrefix.length);
				if (currentNode.children.exists(remainingKey)) {
					currentNode = currentNode.children.get(remainingKey);
					currentKey = remainingKey;
				} else {
					var newChild = new Node<T>(remainingKey, value);
					currentNode.children.set(remainingKey, newChild);
					return;
				}
			} else {
				var newNode = new Node<T>(commonPrefix);
				var nodeRemainingLabel = currentNode.label.substr(commonPrefix.length);
				newNode.children.set(nodeRemainingLabel, currentNode);

				var keyRemainingLabel = currentKey.substr(commonPrefix.length);
				var newChild = new Node<T>(keyRemainingLabel, value);
				newNode.children.set(keyRemainingLabel, newChild);

				currentNode.label = commonPrefix;
				currentNode.children = newNode.children;
				return;
			}
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
		var node = searchNode(root, key);
		return (node != null && node.value != null) ? node.value : null;
	}

	/**
	 * Recursively searches for a node with the given key.
	 *
	 * @param node The current node being searched.
	 * @param key The key to be searched.
	 * @return The node associated with the key, or null if the key is not found.
	 */
	private function searchNode(node:Node<T>, key:String):Node<T> {
		if (node == null) {
			return null;
		}

		if (node.label == key) {
			return node;
		}

		var commonPrefix = getCommonPrefix(node.label, key);
		if (commonPrefix == node.label) {
			var remainingKey = key.substr(commonPrefix.length);
			return searchNode(node.children.get(remainingKey), remainingKey);
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
class Node<T> {
	public var label:String;
	public var value:Null<T>;
	public var children:Map<String, Node<T>>;

	/**
	 * Constructs a new Node.
	 *
	 * @param label The label of the node.
	 * @param value The value to be associated with the node (default is null).
	 */
	public function new(label:String, value:Null<T> = null) {
		this.label = label;
		this.value = value;
		this.children = new Map<String, Node<T>>();
	}
}
