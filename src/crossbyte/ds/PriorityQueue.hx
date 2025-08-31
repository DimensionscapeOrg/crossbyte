package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * A Priority Queue implementation in Haxe using a binary heap.
 *
 * @param T The type of values to be stored in the queue.
 */
class PriorityQueue<T> {
	private var heap:Array<T>;
	private var comparator:(T, T) -> Int;

	/**
	 * Constructs a new PriorityQueue.
	 *
	 * @param comparator A function to compare two elements (negative if first is less, zero if equal, positive if greater).
	 */
	public function new(comparator:(T, T) -> Int) {
		this.heap = [];
		this.comparator = comparator;
	}

	/**
	 * Inserts a value into the priority queue.
	 *
	 * @param value The value to be inserted.
	 */
	public function enqueue(value:T):Void {
		heap.push(value);
		siftUp(heap.length - 1);
	}

	/**
	 * Removes and returns the highest priority value from the queue.
	 *
	 * @return The highest priority value.
	 */
	public function dequeue():Null<T> {
		if (heap.length == 0)
			return null;
		var root = heap[0];
		var last = heap.pop();
		if (heap.length > 0) {
			heap[0] = last;
			siftDown(0);
		}
		return root;
	}

	/**
	 * Returns the highest priority value without removing it.
	 *
	 * @return The highest priority value.
	 */
	public function peek():Null<T> {
		return heap.length > 0 ? heap[0] : null;
	}

	private function siftUp(index:Int):Void {
		var parentIndex = (index - 1) >> 1;
		while (index > 0 && comparator(heap[index], heap[parentIndex]) < 0) {
			swap(index, parentIndex);
			index = parentIndex;
			parentIndex = (index - 1) >> 1;
		}
	}

	private function siftDown(index:Int):Void {
		var leftChild = (index << 1) + 1;
		var rightChild = leftChild + 1;
		var smallest = index;
		if (leftChild < heap.length && comparator(heap[leftChild], heap[smallest]) < 0) {
			smallest = leftChild;
		}
		if (rightChild < heap.length && comparator(heap[rightChild], heap[smallest]) < 0) {
			smallest = rightChild;
		}
		if (smallest != index) {
			swap(index, smallest);
			siftDown(smallest);
		}
	}

	private function swap(i:Int, j:Int):Void {
		var temp = heap[i];
		heap[i] = heap[j];
		heap[j] = temp;
	}
}
