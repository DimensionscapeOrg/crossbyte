package crossbyte._internal.http;

import crossbyte._internal.http.RequestBodyMemory.BodyRoomWaiter;
import crossbyte.core.CrossByte;
import crossbyte.http.HTTPTestSupport;
import utest.Assert;

/**
	The count `HTTPServerConfig.maxRequestBodyMemory` keeps, alone: room
	taken and given back, waiters served in the order they came, and told on
	their runtime.
**/
class RequestBodyMemoryTest extends utest.Test {
	/** Room is taken up to the limit, counted, and given back. **/
	public function testRoomIsTakenUpToTheLimitAndGivenBack():Void {
		var memory = new RequestBodyMemory(100 * 1024, 0);
		var one = new Recorder(memory);
		Assert.equals(60 * 1024, memory.take(60 * 1024, one.waiter));
		Assert.equals(40 * 1024, memory.take(60 * 1024, one.waiter), "less than there was room for was given");
		Assert.isTrue(one.waiter.queued, "a waiter given less than it wanted was not queued for the rest");
		Assert.equals(100.0 * 1024, memory.held);
		memory.cancel(one.waiter);
		memory.release(100 * 1024);
		Assert.equals(0.0, memory.held);
	}

	/** Waiters are served in the order they came, and nobody takes ahead of them. **/
	public function testWaitersAreServedInTheOrderTheyCame():Void {
		var memory = new RequestBodyMemory(64 * 1024, 0);
		var holder = new Recorder(memory);
		var first = new Recorder(memory);
		var second = new Recorder(memory);
		var late = new Recorder(memory);
		Assert.equals(64 * 1024, memory.take(64 * 1024, holder.waiter));
		Assert.equals(0, memory.take(32 * 1024, first.waiter));
		Assert.equals(0, memory.take(32 * 1024, second.waiter));

		memory.release(32 * 1024);
		// Room for one: the first gets it, and one coming now does not jump the queue.
		Assert.equals(0, memory.take(1024, late.waiter), "a newcomer took room the queue was waiting for");
		HTTPTestSupport.pumpUntil(() -> first.given > 0, 2.0);
		Assert.equals(32 * 1024, first.given);
		Assert.equals(0, second.given, "the second was served before the first");

		memory.release(32 * 1024);
		HTTPTestSupport.pumpUntil(() -> second.given > 0, 2.0);
		Assert.equals(32 * 1024, second.given);
		Assert.equals(64.0 * 1024, memory.held);
		memory.cancel(late.waiter);
	}

	/** A waiter is not woken for a few bytes: it waits for MIN_GRANT, or all it wants. **/
	public function testAWaiterIsWokenForAWorthwhileGrant():Void {
		var memory = new RequestBodyMemory(64 * 1024, 0);
		var holder = new Recorder(memory);
		var waiting = new Recorder(memory);
		memory.take(64 * 1024, holder.waiter);
		memory.take(48 * 1024, waiting.waiter);

		memory.release(1024);
		HTTPTestSupport.pumpMore(5);
		Assert.equals(0, waiting.told, "woken for a kilobyte");

		memory.release(RequestBodyMemory.MIN_GRANT);
		HTTPTestSupport.pumpUntil(() -> waiting.told > 0, 2.0);
		Assert.equals(1024 + RequestBodyMemory.MIN_GRANT, waiting.given, "given less than there was room for");
		Assert.isFalse(waiting.waiter.queued, "a waiter given part of what it wanted stays queued, so it would be told twice");
	}

	/** A waiter cancelled before it was told gives back what it was given, which goes to the next. **/
	public function testACancelledWaitersRoomGoesToTheNext():Void {
		var memory = new RequestBodyMemory(64 * 1024, 0);
		var holder = new Recorder(memory);
		var gone = new Recorder(memory);
		var next = new Recorder(memory);
		memory.take(64 * 1024, holder.waiter);
		memory.take(32 * 1024, gone.waiter);
		memory.take(32 * 1024, next.waiter);

		memory.release(32 * 1024);
		// Given to `gone`, which leaves before it is told.
		memory.cancel(gone.waiter);
		HTTPTestSupport.pumpUntil(() -> next.given > 0, 2.0);
		Assert.equals(32 * 1024, next.given, "the room a cancelled waiter had was lost");
		Assert.equals(0, gone.given);
		Assert.equals(64.0 * 1024, memory.held);
	}

	/** Lifting the limit gives every waiter what it wants, and the count goes on. **/
	public function testLiftingTheLimitServesEveryWaiter():Void {
		var memory = new RequestBodyMemory(64 * 1024, 0);
		var holder = new Recorder(memory);
		var a = new Recorder(memory);
		var b = new Recorder(memory);
		memory.take(64 * 1024, holder.waiter);
		memory.take(10 * 1024, a.waiter);
		memory.take(20 * 1024, b.waiter);

		memory.configure(0, 0);
		HTTPTestSupport.pumpUntil(() -> a.given > 0 && b.given > 0, 2.0);
		Assert.equals(10 * 1024, a.given);
		Assert.equals(20 * 1024, b.given);
		Assert.equals(94.0 * 1024, memory.held, "what is held stopped being counted with the limit");
		Assert.equals(5000, memory.take(5000, a.waiter), "no limit, and still not all was given");
	}

	/** The limit is never below the largest body taken. **/
	public function testTheLimitIsNeverBelowTheFloor():Void {
		var memory = new RequestBodyMemory(1024, 64 * 1024);
		var one = new Recorder(memory);
		Assert.equals(64 * 1024, memory.take(64 * 1024, one.waiter));
	}
}

/** A waiter that collects and adds up what it is given each time it is told. */
private class Recorder {
	public var given:Int = 0;
	public var told:Int = 0;
	public final waiter:BodyRoomWaiter;

	private final __memory:RequestBodyMemory;

	public function new(memory:RequestBodyMemory) {
		__memory = memory;
		waiter = new BodyRoomWaiter(CrossByte.current(), __onRoom);
	}

	private function __onRoom():Void {
		told++;
		given += __memory.collect(waiter);
	}
}
