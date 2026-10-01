package crossbyte.events;

import utest.Assert;

@:access(crossbyte.events.EventDispatcher)
class EventDispatcherTest extends utest.Test {
	public function testAContainedDispatchRunsEveryListenerPastOneThatThrows():Void {
		var dispatcher = new FailureRecorder();
		var order:Array<String> = [];

		dispatcher.addEventListener("demo", (_:Event) -> order.push("first"));
		dispatcher.addEventListener("demo", (_:Event) -> {
			order.push("second");
			throw "listener bug";
		});
		dispatcher.addEventListener("demo", (_:Event) -> order.push("third"));

		Assert.isTrue(dispatcher.__dispatchContained(new Event("demo")));
		Assert.same(["first", "second", "third"], order);
		Assert.same(["listener bug"], dispatcher.failures);

		// The ordinary dispatch is unchanged: a component dispatching its own
		// events still hears that a listener failed.
		Assert.raises(() -> dispatcher.dispatchEvent(new Event("demo")));
	}

	public function testHigherPriorityRunsFirst():Void {
		var dispatcher = new EventDispatcher();
		var order:Array<String> = [];

		dispatcher.addEventListener("demo", (_:Event) -> order.push("default"));
		dispatcher.addEventListener("demo", (_:Event) -> order.push("high"), 10);
		dispatcher.addEventListener("demo", (_:Event) -> order.push("mid"), 5);

		dispatcher.dispatchEvent(new Event("demo"));

		Assert.same(["high", "mid", "default"], order);
	}

	/**
		What the doc says `priority` is: an ordering, not the insertion index
		it used to call it. Ties run in the order added, a negative priority
		runs after the default, and a large one is not clamped to anything.
	**/
	public function testEqualPrioritiesRunInTheOrderAddedAndNegativesRunLast():Void {
		var dispatcher = new EventDispatcher();
		var order:Array<String> = [];

		dispatcher.addEventListener("demo", (_:Event) -> order.push("0a"));
		dispatcher.addEventListener("demo", (_:Event) -> order.push("5a"), 5);
		dispatcher.addEventListener("demo", (_:Event) -> order.push("-1"), -1);
		dispatcher.addEventListener("demo", (_:Event) -> order.push("5b"), 5);
		dispatcher.addEventListener("demo", (_:Event) -> order.push("0b"));
		dispatcher.addEventListener("demo", (_:Event) -> order.push("1000"), 1000);

		dispatcher.dispatchEvent(new Event("demo"));

		Assert.same(["1000", "5a", "5b", "0a", "0b", "-1"], order);
	}

	public function testDelegatedDispatcherSetsTargetAndCurrentTargetToOwner():Void {
		var owner = new DispatcherOwner();
		var event = new Event("demo");
		var seenTarget:Dynamic = null;
		var seenCurrentTarget:Dynamic = null;

		owner.addEventListener("demo", (received:Event) -> {
			seenTarget = received.target;
			seenCurrentTarget = received.currentTarget;
		});

		owner.dispatch(event);

		Assert.equals(owner, seenTarget);
		Assert.equals(owner, seenCurrentTarget);
	}

	public function testAddingListenerDuringDispatchDoesNotAffectCurrentEvent():Void {
		var dispatcher = new EventDispatcher();
		var calls = 0;
		var lateCalls = 0;
		var lateListener = (_:Event) -> lateCalls++;

		dispatcher.addEventListener("demo", (_:Event) -> {
			calls++;
			dispatcher.addEventListener("demo", lateListener);
		});

		dispatcher.dispatchEvent(new Event("demo"));
		dispatcher.dispatchEvent(new Event("demo"));

		Assert.equals(2, calls);
		Assert.equals(1, lateCalls);
	}

	public function testRemovingListenerDuringDispatchDoesNotSkipSnapshotListeners():Void {
		var dispatcher = new EventDispatcher();
		var calls:Array<String> = [];
		var second:Event->Void = null;

		second = (_:Event) -> calls.push("second");
		dispatcher.addEventListener("demo", (_:Event) -> {
			calls.push("first");
			dispatcher.removeEventListener("demo", second);
		});
		dispatcher.addEventListener("demo", second);

		dispatcher.dispatchEvent(new Event("demo"));
		dispatcher.dispatchEvent(new Event("demo"));

		Assert.same(["first", "second", "first"], calls);
	}

	public function testOutsideADispatchTheListIsChangedWhereItIs():Void {
		// Every add and every remove copied the whole list, dispatching or
		// not, so n connections or tasks each attaching a listener cost n^2
		// to attach and again to detach. Only a list a dispatch is walking
		// needs replacing.
		var dispatcher = new EventDispatcher();
		var first = (_:Event) -> {};
		var second = (_:Event) -> {};
		var third = (_:Event) -> {};
		dispatcher.addEventListener("demo", first);
		dispatcher.addEventListener("demo", second);
		var list = dispatcher.__eventMap.get("demo");

		dispatcher.addEventListener("demo", third);
		Assert.equals(list, dispatcher.__eventMap.get("demo"), "adding copied the list");
		dispatcher.addEventListener("demo", (_:Event) -> {}, 5);
		Assert.equals(list, dispatcher.__eventMap.get("demo"), "adding ahead of the others copied the list");
		dispatcher.removeEventListener("demo", second);
		Assert.equals(list, dispatcher.__eventMap.get("demo"), "removing copied the list");
		Assert.equals(3, list.length);
	}

	public function testChangesMadeDuringAWalkLeaveTheWalkAlone():Void {
		// With the list changed in place outside a dispatch, the walk is what
		// must not see it change: a listener removed further down still runs
		// for this event, one added does not, and nothing runs twice.
		var dispatcher = new EventDispatcher();
		var calls:Array<String> = [];
		var third:Event->Void = (_:Event) -> calls.push("third");
		var late:Event->Void = (_:Event) -> calls.push("late");

		dispatcher.addEventListener("demo", (_:Event) -> {
			calls.push("first");
			dispatcher.removeEventListener("demo", third);
		});
		dispatcher.addEventListener("demo", (_:Event) -> {
			calls.push("second");
			dispatcher.addEventListener("demo", late, 10);
		});
		dispatcher.addEventListener("demo", third);

		dispatcher.dispatchEvent(new Event("demo"));
		Assert.same(["first", "second", "third"], calls);

		calls = [];
		dispatcher.removeEventListener("demo", late);
		dispatcher.dispatchEvent(new Event("demo"));
		// The second listener adds `late` again during this walk, so it runs
		// from the next one.
		Assert.same(["first", "second"], calls);
	}

	public function testANestedDispatchLeavesTheOuterWalkAlone():Void {
		var dispatcher = new EventDispatcher();
		var calls:Array<String> = [];
		var last:Event->Void = (_:Event) -> calls.push("outer last");

		dispatcher.addEventListener("outer", (_:Event) -> {
			calls.push("outer first");
			dispatcher.dispatchEvent(new Event("inner"));
		});
		dispatcher.addEventListener("outer", last);
		dispatcher.addEventListener("inner", (_:Event) -> {
			calls.push("inner");
			dispatcher.removeEventListener("outer", last);
		});
		dispatcher.addEventListener("inner", (_:Event) -> {});

		dispatcher.dispatchEvent(new Event("outer"));
		Assert.same(["outer first", "inner", "outer last"], calls);
		Assert.equals(0, dispatcher.__walking);
	}

	public function testAListenerThatThrowsOutOfADispatchLeavesTheDispatcherCorrect():Void {
		// The walk count stays raised when a listener's failure leaves
		// dispatchEvent, so from then on every change copies, as every change
		// once did, slower, and still right.
		var dispatcher = new EventDispatcher();
		var calls:Array<String> = [];
		var failing = true;
		var late:Event->Void = (_:Event) -> calls.push("late");

		dispatcher.addEventListener("demo", (_:Event) -> {
			calls.push("first");
			if (failing) {
				throw "listener bug";
			}
			dispatcher.addEventListener("demo", late);
		});
		dispatcher.addEventListener("demo", (_:Event) -> calls.push("second"));

		Assert.raises(() -> dispatcher.dispatchEvent(new Event("demo")));
		failing = false;

		calls = [];
		dispatcher.dispatchEvent(new Event("demo"));
		Assert.same(["first", "second"], calls);

		calls = [];
		dispatcher.removeEventListener("demo", late);
		dispatcher.dispatchEvent(new Event("demo"));
		Assert.same(["first", "second"], calls);

		calls = [];
		dispatcher.dispatchEvent(new Event("demo"));
		Assert.same(["first", "second", "late"], calls);
	}

	public function testABoundMethodIsRemovedByAFreshReadOfIt():Void {
		// `removeEventListener(type, this.onTick)` reads the method again. On
		// eval and the jvm every read is a new closure that `==` never matches,
		// so the listener stayed attached for good: a closed socket or a
		// stopped timer went on being called.
		var dispatcher = new EventDispatcher();
		var subscriber = new MethodSubscriber();
		dispatcher.addEventListener("demo", subscriber.handle);
		dispatcher.removeEventListener("demo", subscriber.handle);
		dispatcher.dispatchEvent(new Event("demo"));

		Assert.equals(0, subscriber.calls, "the removed method was still called");
		Assert.isFalse(dispatcher.hasEventListener("demo"));
	}

	public function testRemovingOneObjectsMethodLeavesAnothersAttached():Void {
		var dispatcher = new EventDispatcher();
		var first = new MethodSubscriber();
		var second = new MethodSubscriber();
		dispatcher.addEventListener("demo", first.handle);
		dispatcher.addEventListener("demo", second.handle);
		dispatcher.removeEventListener("demo", first.handle);
		dispatcher.dispatchEvent(new Event("demo"));

		Assert.equals(0, first.calls);
		Assert.equals(1, second.calls);
	}
}

private class MethodSubscriber {
	public var calls:Int = 0;

	public function new() {}

	public function handle(_:Event):Void {
		calls++;
	}
}

private class DispatcherOwner implements IEventDispatcher {
	private var dispatcher:EventDispatcher;

	public function new() {
		dispatcher = new EventDispatcher(this);
	}

	public function addEventListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		dispatcher.addEventListener(type, listener, priority);
	}

	public function dispatchEvent<T:Event>(event:T):Bool {
		return dispatcher.dispatchEvent(event);
	}

	public function dispatch(event:Event):Bool {
		return dispatcher.dispatchEvent(event);
	}
}

private class FailureRecorder extends EventDispatcher {
	public var failures:Array<Dynamic> = [];

	public function new() {
		super();
	}

	override private function __listenerThrew(error:Dynamic, event:Event):Void {
		failures.push(error);
	}
}
