package crossbyte.ds;

import crossbyte.test.Require;
import utest.Assert;

private class Ticket {
	public var id:Int;
	public var priority:Int;
	public var enqueuedAt:Int;

	public function new(id:Int, priority:Int, enqueuedAt:Int) {
		this.id = id;
		this.priority = priority;
		this.enqueuedAt = enqueuedAt;
	}
}

class PriorityQueueTest extends utest.Test {
	/**
		A matchmaker at one priority serves its tickets in the order they came.

		Moving the newest ticket to the root on a dequeue, a strict comparison
		would never sink it past an equal, so the newest would be served next:
		with three tickets in and three out a tick behind a ten-tick backlog,
		29 of the first 30 would still be waiting at tick 20,000. First come,
		first served makes every wait exactly the backlog.
	**/
	public function testEqualPrioritiesAreServedInTheOrderTheyCame():Void {
		var queue = new PriorityQueue<Ticket>((a, b) -> a.priority - b.priority);
		var nextId:Int = 0;
		var nextServed:Int = 0;
		var outOfTurn:Int = 0;
		var longestWait:Int = 0;
		for (tick in 0...2000) {
			for (_ in 0...3) {
				queue.enqueue(new Ticket(nextId++, 5, tick));
			}
			if (tick >= 10) {
				for (_ in 0...3) {
					var served = queue.dequeue();
					if (served.id != nextServed) {
						outOfTurn++;
					}
					nextServed++;
					var wait:Int = tick - served.enqueuedAt;
					if (wait > longestWait) {
						longestWait = wait;
					}
				}
			}
		}
		Assert.equals(0, outOfTurn, outOfTurn + " of " + nextServed + " tickets were served out of turn");
		Assert.equals(10, longestWait, "a ticket waited " + longestWait + " ticks behind a backlog of 10");

		var oldest:Int = 1 << 30;
		while (!queue.isEmpty) {
			var left = queue.dequeue();
			if (left.enqueuedAt < oldest) {
				oldest = left.enqueuedAt;
			}
		}
		Assert.equals(1990, oldest, "the tickets left waiting were not the last ten ticks' worth");
	}

	/**
		`peek` answers the element `dequeue` would, for a class of element.
		Inlined, it would read the queue's storage as an array of that class on
		the jvm, which the erased array is not: a ClassCastException.
	**/
	public function testPeekAnswersWhatDequeueWould():Void {
		var queue = new PriorityQueue<Ticket>((a, b) -> a.priority - b.priority);
		Assert.isNull(queue.peek());
		queue.enqueue(new Ticket(1, 5, 0));
		queue.enqueue(new Ticket(2, 3, 0));
		queue.enqueue(new Ticket(3, 3, 1));
		var next = Require.notNull(queue.peek());
		Assert.equals(2, next.id);
		Assert.equals(next, queue.dequeue());
		Assert.equals(3, Require.notNull(queue.peek()).id);
	}

	/** Among equals the oldest goes first, whatever else is in the heap. **/
	public function testTiesBreakByArrivalAcrossPriorities():Void {
		var queue = new PriorityQueue<Ticket>((a, b) -> a.priority - b.priority);
		var tickets:Array<Ticket> = [];
		// Priorities interleaved so equals end up spread across the heap.
		for (i in 0...60) {
			var ticket = new Ticket(i, i % 3, i);
			tickets.push(ticket);
			queue.enqueue(ticket);
		}
		var served:Array<String> = [];
		while (!queue.isEmpty) {
			var t = queue.dequeue();
			served.push(t.priority + ":" + t.id);
		}
		var expected:Array<String> = [];
		for (priority in 0...3) {
			for (t in tickets) {
				if (t.priority == priority) {
					expected.push(t.priority + ":" + t.id);
				}
			}
		}
		Assert.equals(expected.join(","), served.join(","));
	}

	/**
		An element whose priority changes keeps its place in line among its
		new equals: a ticket promoted after waiting goes ahead of the ones that
		arrived after it at that priority.
	**/
	public function testAnUpdatedElementKeepsItsPlaceInLine():Void {
		var queue = new PriorityQueue<Ticket>((a, b) -> a.priority - b.priority);
		var early = new Ticket(0, 9, 0);
		queue.enqueue(early);
		var later = [for (i in 1...6) new Ticket(i, 1, i)];
		for (t in later) {
			queue.enqueue(t);
		}

		early.priority = 1;
		queue.update(early);
		Assert.equals(0, queue.dequeue().id, "the promoted ticket lost its place to newer ones");

		// Enqueuing one already held is an update, and keeps it held once.
		var first = later[0];
		first.priority = 1;
		queue.enqueue(first);
		Assert.equals(5, queue.size);
		Assert.equals(1, queue.dequeue().id);
	}

	/**
		A queue kept by a generic class holds whatever that class is given.

		This is why the queue is not specialised per element type: a
		`@:generic` class used where its type is still a parameter falls back
		to its unspecialised body, whose element map is an `IntMap`, and the
		first object enqueued there would throw.
	**/
	public function testAQueueHeldByAGenericClass():Void {
		var holder = new QueueHolder<Ticket>((a, b) -> a.priority - b.priority);
		holder.queue.enqueue(new Ticket(0, 2, 0));
		holder.queue.enqueue(new Ticket(1, 1, 0));
		holder.queue.enqueue(new Ticket(2, 1, 0));
		Assert.equals(1, holder.queue.dequeue().id);
		Assert.equals(2, holder.queue.dequeue().id);
		Assert.equals(0, holder.queue.dequeue().id);
	}

	/**
		A queue of plain ids, which is what a matchmaker keyed on player ids
		holds. `PriorityQueue<Int>` does not compile (its elements are
		objects), so ids go in an `IntPriorityQueue`, which holds each one's
		priority beside it.
	**/
	public function testAnIntQueueServesLowestFirstAndEqualsInOrder():Void {
		var queue = new IntPriorityQueue(4);
		for (i in 0...40) {
			queue.enqueue(100000 + i, i % 4);
		}
		Assert.equals(40, queue.size);
		Assert.isTrue(queue.contains(100007));
		Assert.equals(3.0, queue.priorityOf(100007));
		Assert.isTrue(queue.remove(100007));
		Assert.isFalse(queue.contains(100007));
		Assert.isFalse(queue.remove(100007));
		Assert.isTrue(Math.isNaN(queue.priorityOf(100007)));

		var served:Array<Int> = [];
		while (!queue.isEmpty) {
			served.push(queue.dequeue());
		}
		var expected:Array<Int> = [];
		for (r in 0...4) {
			for (i in 0...40) {
				if (i != 7 && i % 4 == r) {
					expected.push(100000 + i);
				}
			}
		}
		Assert.equals(expected.join(","), served.join(","));
		Assert.raises(() -> queue.dequeue());
		Assert.raises(() -> queue.peek());
	}

	/**
		Enqueuing an id already held changes its priority and keeps its place
		in line among its new equals, as `update` does for objects.
	**/
	public function testAnIntQueueReprioritisesInPlace():Void {
		var queue = new IntPriorityQueue();
		queue.enqueue(-5, 9);
		for (id in 1...6) {
			queue.enqueue(id, 1);
		}
		queue.enqueue(-5, 1);
		Assert.equals(6, queue.size, "an id already held was held twice");
		Assert.equals(-5, queue.peek());
		Assert.equals(1.0, queue.peekPriority());
		Assert.equals(-5, queue.dequeue());

		queue.enqueue(4, -1);
		Assert.equals(4, queue.dequeue(), "a lowered priority did not come to the front");
		queue.enqueue(1, 50);
		Assert.equals("2,3,5,1", [while (!queue.isEmpty) queue.dequeue()].join(","));

		Assert.raises(() -> queue.enqueue(1, Math.NaN));
		queue.enqueue(0, Math.NEGATIVE_INFINITY);
		queue.enqueue(0x7FFFFFFF, Math.POSITIVE_INFINITY);
		queue.clear();
		Assert.isTrue(queue.isEmpty);
		Assert.isFalse(queue.contains(0));
	}

	/**
		The order holds through growth and slot reuse: a matchmaker's steady
		state at one priority, as for the object queue, across ids large
		enough to box.
	**/
	public function testAnIntQueueIsFirstComeFirstServedAtOnePriority():Void {
		var queue = new IntPriorityQueue(2);
		var nextId:Int = 0;
		var nextServed:Int = 0;
		var outOfTurn:Int = 0;
		for (tick in 0...2000) {
			for (_ in 0...3) {
				queue.enqueue(1000000 + nextId++, 5.0);
			}
			if (tick >= 10) {
				for (_ in 0...3) {
					if (queue.dequeue() != 1000000 + nextServed) {
						outOfTurn++;
					}
					nextServed++;
				}
			}
		}
		Assert.equals(0, outOfTurn, outOfTurn + " of " + nextServed + " ids were served out of turn");
		Assert.equals(30, queue.size);
	}

	/** Clearing starts the arrival count over without mixing up the order. **/
	public function testClearThenReuse():Void {
		var queue = new PriorityQueue<Ticket>((a, b) -> a.priority - b.priority);
		for (i in 0...10) {
			queue.enqueue(new Ticket(i, 0, i));
		}
		queue.clear();
		Assert.isTrue(queue.isEmpty);
		Assert.isNull(queue.peek());
		for (i in 10...50) {
			queue.enqueue(new Ticket(i, 0, i));
		}
		var ids:Array<Int> = [];
		while (!queue.isEmpty) {
			ids.push(queue.dequeue().id);
		}
		Assert.equals([for (i in 10...50) i].join(","), ids.join(","));
	}
}

private class QueueHolder<T:{}> {
	public var queue:PriorityQueue<T>;

	public function new(comparator:(T, T) -> Int) {
		queue = new PriorityQueue<T>(comparator);
	}
}
