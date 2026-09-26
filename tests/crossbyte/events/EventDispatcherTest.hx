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
