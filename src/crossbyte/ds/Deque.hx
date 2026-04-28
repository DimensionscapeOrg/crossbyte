package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
 */
class DequeNode<T> {
	public var value:T;
	public var next:DequeNode<T>;
	public var prev:DequeNode<T>;

	public function new(value:T) {
		this.value = value;
		this.next = null;
		this.prev = null;
	}
}

class Deque<T> {
	private var head:DequeNode<T>;
	private var tail:DequeNode<T>;
	private var _size:Int;

	public function new() {
		head = null;
		tail = null;
		_size = 0;
	}

	public function add(item:T):Void {
		var node = new DequeNode(item);
		if (head == null) {
			head = node;
			tail = node;
		} else {
			node.next = head;
			head.prev = node;
			head = node;
		}
		_size++;
	}

	public function push(item:T):Void {
		var node = new DequeNode(item);
		if (tail == null) {
			head = node;
			tail = node;
		} else {
			node.prev = tail;
			tail.next = node;
			tail = node;
		}
		_size++;
	}

	public function pop():T {
		if (head == null)
			throw "Deque is empty";
		var value = head.value;
		head = head.next;
		if (head != null)
			head.prev = null;
		else
			tail = null;
		_size--;
		return value;
	}

	public function remove():T {
		if (tail == null)
			throw "Deque is empty";
		var value = tail.value;
		tail = tail.prev;
		if (tail != null)
			tail.next = null;
		else
			head = null;
		_size--;
		return value;
	}

	public function first():T {
		if (head == null)
			throw "Deque is empty";
		return head.value;
	}

	public function last():T {
		if (tail == null)
			throw "Deque is empty";
		return tail.value;
	}

	public function isEmpty():Bool {
		return _size == 0;
	}

	public function size():Int {
		return _size;
	}
}
