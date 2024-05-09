package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
 */
class RadixTree<T>
{

	private var root: Node;

	public function new()
	{
		root = new Node("");
	}

	public function insert(key: String, value: T): Void
	{
		root = insertRecursive(root, key, value);
	}

	private function insertRecursive(node: Node, key: String, value: T): Node
	{
		if (node == null)
		{
			return new Node(key, value);
		}

		var commonPrefix = getCommonPrefix(node.label, key);
		if (commonPrefix.length == 0)
		{
			var child = new Node(key, value);
			node.children.set(key, child);
			return node;
		}

		if (commonPrefix == node.label)
		{
			var remainingKey = key.substr(commonPrefix.length);
			var child = insertRecursive(node.children.get(remainingKey), remainingKey, value);
			node.children.set(remainingKey, child);
			return node;
		}

		var newNode = new Node(commonPrefix);
		var nodeRemainingLabel = node.label.substr(commonPrefix.length);
		newNode.children.set(nodeRemainingLabel, node);

		var keyRemainingLabel = key.substr(commonPrefix.length);
		var newChild = new Node(keyRemainingLabel, value);
		newNode.children.set(keyRemainingLabel, newChild);

		return newNode;
	}

	public function search(key: String): Null<T>
	{
		var node = searchNode(root, key);
		return (node != null && node.value != null) ? node.value : null;
	}

	private function searchNode(node: Node, key: String): Node
	{
		if (node == null)
		{
			return null;
		}

		if (node.label == key)
		{
			return node;
		}

		var commonPrefix = getCommonPrefix(node.label, key);
		if (commonPrefix == node.label)
		{
			var remainingKey = key.substr(commonPrefix.length);
			return searchNode(node.children.get(remainingKey), remainingKey);
		}

		return null;
	}

	private function getCommonPrefix(str1: String, str2: String): String
	{
		var minLength = Math.min(str1.length, str2.length);
		var prefix = "";
		for (i in 0...minLength)
		{
			if (str1.charAt(i) != str2.charAt(i))
			{
				break;
			}
			prefix += str1.charAt(i);
		}
		return prefix;
	}
}

@:private 
@:noCompletion 
class Node
{
	var label: String;
	var value: Null<T>;
	var children: Map<String, Node>;

	public function new(label: String, value: Null<T> = null)
	{
		this.label = label;
		this.value = value;
		this.children = new Map<String, Node>();
	}
}