package crossbyte.events;

import utest.Assert;

/**
	CrossByte's dispatcher: Emitter's, with ActionScript's names. What Emitter
	does itself (its lists, their copies during a dispatch) is tested in
	Emitter; these hold what CrossByte relies on and adds.
**/
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

		Assert.isTrue(dispatcher.dispatchContained(new Event("demo")));
		Assert.same(["first", "second", "third"], order);
		Assert.same(["listener bug"], dispatcher.failures);

		// The ordinary dispatch: a component dispatching its own events still
		// hears that a listener failed.
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
		What the doc says `priority` is: an ordering, not an insertion index.
		Ties run in the order added, a negative priority runs after the default,
		and a large one is not clamped to anything.
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

		owner.events.dispatch(event);

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
		calls = [];
		dispatcher.dispatchEvent(new Event("outer"));
		Assert.same(["outer first", "inner"], calls, "the listener the nested dispatch removed was called again");
	}

	public function testAListenerThatThrowsOutOfADispatchLeavesTheDispatcherCorrect():Void {
		// A listener's failure ends dispatchEvent, reaches the caller, and
		// leaves the dispatcher as it was: the next dispatch, and every add and
		// remove after it, behave as if nothing had thrown.
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

		Assert.raises(() -> dispatcher.dispatchEvent(new Event("demo")), String);
		var other:Event->Void = (_:Event) -> calls.push("other");
		dispatcher.addEventListener("demo", other);
		dispatcher.removeEventListener("demo", other);
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
		// so compared that way the listener would stay attached for good: a
		// closed socket or a stopped timer would go on being called.
		var dispatcher = new EventDispatcher();
		var subscriber = new MethodSubscriber();
		dispatcher.addEventListener("demo", subscriber.handle);
		dispatcher.removeEventListener("demo", subscriber.handle);
		dispatcher.dispatchEvent(new Event("demo"));

		Assert.equals(0, subscriber.calls, "the removed method was still called");
		Assert.isFalse(dispatcher.hasEventListener("demo"));
	}

	/**
		A listener that hands its event on to another dispatcher leaves the
		dispatch it is part of as it was: the listeners after it still see the
		event's `currentTarget` as the dispatcher they are listening to. The
		inner dispatch set it to the other dispatcher and left it there, so a
		wrapper forwarding its socket's events told the socket's remaining
		listeners they were the wrapper's.
	**/
	public function testForwardingAnEventLeavesTheDispatchItCameFromAlone():Void {
		var inner = new EventDispatcher();
		var outer = new EventDispatcher();
		var seenOnOuter:Dynamic = null;
		var seenAfter:Array<Dynamic> = [];
		outer.addEventListener("demo", (event:Event) -> seenOnOuter = event.currentTarget);
		inner.addEventListener("demo", (event:Event) -> outer.dispatchEvent(event));
		inner.addEventListener("demo", (event:Event) -> seenAfter.push(event.currentTarget));

		inner.dispatchEvent(new Event("demo"));
		Assert.equals(outer, seenOnOuter);
		Assert.equals(1, seenAfter.length);
		Assert.equals(inner, seenAfter[0], "a listener after the forward was told it listened to the other dispatcher");

		// The same from a runtime's tick, which contains its listeners' failures.
		var contained = new FailureRecorder();
		seenAfter = [];
		contained.addEventListener("demo", (event:Event) -> outer.dispatchEvent(event));
		contained.addEventListener("demo", (event:Event) -> seenAfter.push(event.currentTarget));
		contained.dispatchContained(new Event("demo"));
		Assert.equals(contained, seenAfter[0]);
	}

	/**
		The next dispatch, and `hasEventListener`, see every listener added
		or removed since the last, from inside a dispatch (which puts a new
		list in place of the one being walked) or out of one. Natively a type
		is found first by which string it is, so a type with the same text
		made apart from the one added is found too, and a null type matches
		no other.
	**/
	public function testADispatchSeesEveryChangeMadeSinceTheLast():Void {
		var dispatcher = new EventDispatcher();
		var calls:Array<String> = [];
		var late = (_:Event) -> calls.push("late");
		var first = function(_:Event):Void {
			calls.push("first");
		};
		dispatcher.addEventListener("demo", first);
		dispatcher.addEventListener("demo", (_:Event) -> {
			calls.push("second");
			if (calls.length == 2) {
				// Added during a walk: the list is replaced.
				dispatcher.addEventListener("demo", late);
			}
		});

		dispatcher.dispatchEvent(new Event("demo"));
		Assert.equals("first,second", calls.join(","));
		calls = [];
		dispatcher.dispatchEvent(new Event("demo"));
		Assert.equals("first,second,late", calls.join(","), "a listener added during the last dispatch was not called by the next");

		// Removed during a walk: the list is replaced again.
		calls = [];
		dispatcher.addEventListener("demo", (_:Event) -> dispatcher.removeEventListener("demo", first), -1);
		dispatcher.dispatchEvent(new Event("demo"));
		calls = [];
		dispatcher.dispatchEvent(new Event("demo"));
		Assert.isTrue(calls.indexOf("first") < 0, "a listener removed during the last dispatch was called by the next");

		// Removed outside a dispatch, down to none.
		dispatcher.removeAllListeners();
		Assert.isFalse(dispatcher.hasEventListener("demo"));
		calls = [];
		Assert.isFalse(dispatcher.dispatchEvent(new Event("demo")));
		Assert.equals(0, calls.length);

		var only = (_:Event) -> calls.push("only");
		dispatcher.addEventListener("demo", only);
		Assert.isTrue(dispatcher.hasEventListener("demo"));
		dispatcher.dispatchEvent(new Event("demo"));
		dispatcher.removeEventListener("demo", only);
		Assert.isFalse(dispatcher.hasEventListener("demo"), "the last listener's removal was not seen");
		calls = [];
		dispatcher.dispatchEvent(new Event("demo"));
		Assert.equals(0, calls.length);

		// A type with the same text, made apart from the one used before.
		dispatcher.addEventListener("demo", only);
		var made:String = ["de", "mo"].join("");
		dispatcher.dispatchEvent(new Event(made));
		Assert.equals("only", calls.join(","));
		Assert.isTrue(dispatcher.hasEventListener(made));
		Assert.isFalse(dispatcher.hasEventListener("other"));
		Assert.isTrue(dispatcher.hasEventListener("demo"));

		// A null type, asked about after a change, is not taken for the type
		// asked about before it. Whether a map takes a null key at all
		// depends on the target (eval and neko throw), so only that is held.
		dispatcher.addEventListener("other", only);
		var unknown:String = null;
		var answered:Null<Bool> = try dispatcher.hasEventListener(unknown) catch (_:Dynamic) null;
		Assert.isFalse(answered == true, "a null type was answered with another type's listeners");
		dispatcher.addEventListener("other", late);
		calls = [];
		try {
			dispatcher.dispatchEvent(new Event(unknown));
		} catch (_:Dynamic) {}
		Assert.equals(0, calls.length, "an event of a null type reached another type's listeners");
	}

	public function testAListenerAddedAgainIsNotAddedAgain():Void {
		// As in ActionScript: it keeps its place and its priority, runs once,
		// and one removal takes it out.
		var dispatcher = new EventDispatcher();
		var calls:Array<String> = [];
		var listener = (_:Event) -> calls.push("listener");
		dispatcher.addEventListener("demo", listener);
		dispatcher.addEventListener("demo", (_:Event) -> calls.push("other"));
		dispatcher.addEventListener("demo", listener);
		dispatcher.addEventListener("demo", listener, 10);
		dispatcher.dispatchEvent(new Event("demo"));
		Assert.equals("listener,other", calls.join(","));

		dispatcher.removeEventListener("demo", listener);
		calls = [];
		dispatcher.dispatchEvent(new Event("demo"));
		Assert.equals("other", calls.join(","), "one removal did not take the listener out");
	}

	public function testTheRuntimeKeepsAListenerAddedTwice():Void {
		// The runtime holds a tick listener per connection, timer and task:
		// adding one is not a search there, so each add is kept, and each
		// removal takes one. A dispatcher may opt out the same way.
		Assert.isTrue(crossbyte.core.CrossByte.current().allowDuplicates, "the runtime searches its listeners on every add");
		Assert.isFalse(new EventDispatcher().allowDuplicates);

		var dispatcher = new EventDispatcher();
		dispatcher.allowDuplicates = true;
		var calls = 0;
		var listener = (_:Event) -> calls++;
		dispatcher.addEventListener("demo", listener);
		dispatcher.addEventListener("demo", listener);
		dispatcher.dispatchEvent(new Event("demo"));
		Assert.equals(2, calls);

		dispatcher.removeEventListener("demo", listener);
		calls = 0;
		dispatcher.dispatchEvent(new Event("demo"));
		Assert.equals(1, calls, "a removal took more than one");

		dispatcher.removeEventListener("demo", listener);
		Assert.isFalse(dispatcher.hasEventListener("demo"));
	}

	/**
		The ActionScript names are Emitter's own words: what one adds the
		other finds and removes, and either name dispatches. A dispatcher
		keeps `clear`, `has` and `dispatch` free for members of its own: the
		words are reached through `events`.
	**/
	public function testTheActionScriptNamesAreEmittersWords():Void {
		var dispatcher = new OwnNames();
		var calls:Array<String> = [];
		var listener = (_:Event) -> calls.push("listener");

		var subscription = dispatcher.events.on(Event.COMPLETE, listener);
		Assert.isTrue(dispatcher.hasEventListener(Event.COMPLETE));
		dispatcher.removeEventListener(Event.COMPLETE, listener);
		Assert.isFalse(subscription.active, "removeEventListener did not take out what on added");
		Assert.isFalse(dispatcher.events.has(Event.COMPLETE));

		dispatcher.addEventListener(Event.COMPLETE, listener);
		Assert.isTrue(dispatcher.events.has(Event.COMPLETE, listener));
		Assert.isTrue(dispatcher.dispatchEvent(new Event(Event.COMPLETE)));
		Assert.isTrue(dispatcher.events.dispatch(new Event(Event.COMPLETE)));
		Assert.isTrue(dispatcher.dispatch(Event.COMPLETE));
		Assert.equals("listener,listener,listener", calls.join(","));
		dispatcher.clear();
		Assert.equals(1, dispatcher.cleared);
		Assert.isTrue(dispatcher.hasEventListener(Event.COMPLETE), "the dispatcher's own clear took its listeners");

		dispatcher.events.off(Event.COMPLETE, listener);
		Assert.isFalse(dispatcher.hasEventListener(Event.COMPLETE));

		dispatcher.addEventListener(Event.COMPLETE, listener);
		dispatcher.events.once(Event.CANCEL, (_:Event) -> calls.push("once"));
		dispatcher.removeAllListeners();
		Assert.isFalse(dispatcher.hasEventListener(Event.COMPLETE));
		Assert.isFalse(dispatcher.hasEventListener(Event.CANCEL));
	}

	/**
		One kind of event: a listener written for Emitter's events takes
		CrossByte's, and a CrossByte dispatcher sends Emitter's.
	**/
	public function testCrossBytesEventsAreEmittersEvents():Void {
		var dispatcher = new EventDispatcher();
		var heard:Array<String> = [];
		dispatcher.addEventListener(Event.COMPLETE, (event:emitter.Event) -> heard.push("emitter:" + event.type));
		dispatcher.addEventListener(emitter.Event.CHANGE, (event:emitter.Event) -> heard.push("change"));
		dispatcher.dispatchEvent(new Event(Event.COMPLETE));
		dispatcher.dispatchEvent(new emitter.Event(emitter.Event.CHANGE));
		Assert.equals("emitter:complete,change", heard.join(","));

		var event:emitter.Event = new TickEvent(TickEvent.TICK, 0.5);
		Assert.isTrue(Std.isOfType(event, emitter.Event));
		Assert.equals("tick", event.toString());
		Assert.isFalse(event.bubbles);
		Assert.isFalse(event.cancelable);
	}

	/**
		A dispatcher keeps a few types in a short chain and more in a map:
		types added and removed in any order, past that limit and back, keep
		their own listeners, and a type added from inside a dispatch, moving
		every type into the map, leaves the walk in progress alone.
	**/
	public function testManyTypesAddedAndRemovedInAnyOrderKeepTheirListeners():Void {
		var dispatcher = new EventDispatcher();
		var heard:Array<String> = [];
		var listeners:Map<String, Event->Void> = new Map();
		var types:Array<String> = [for (i in 0...14) "type" + i];
		for (type in types) {
			// Typed as the map holds it, so the one function is added and
			// removed. Left to its own type (it returns push's Int), HashLink
			// wraps it again for the map, and the map's copy is not the
			// listener added: see docs/targets.md.
			var listener:Event->Void = (event:Event) -> heard.push(type + ":" + event.type);
			listeners.set(type, listener);
			dispatcher.addEventListener(type, listener);
		}
		function check(present:Array<String>, step:String):Void {
			for (type in types) {
				heard = [];
				var listened:Bool = present.indexOf(type) >= 0;
				Assert.equals(listened, dispatcher.hasEventListener(type), step + ": hasEventListener(" + type + ")");
				Assert.equals(listened, dispatcher.dispatchEvent(new Event(type)), step + ": dispatching " + type);
				Assert.equals(listened ? type + ":" + type : "", heard.join(","), step + ": who heard " + type);
			}
		}
		check(types, "all added");

		var present:Array<String> = types.copy();
		for (index in [0, 13, 6, 7, 1, 12, 3, 2, 11, 4, 10, 5, 9]) {
			var type:String = types[index];
			dispatcher.removeEventListener(type, listeners.get(type));
			present.remove(type);
			check(present, "removed " + type);
		}
		for (index in [9, 0, 5, 13]) {
			var type:String = types[index];
			dispatcher.addEventListener(type, listeners.get(type));
			present.push(type);
			check(present, "added back " + type);
		}

		// A listener that adds enough new types to move the rest into a map:
		// the dispatch it is part of still reaches the listener after it.
		var fresh = new EventDispatcher();
		var calls:Array<String> = [];
		fresh.addEventListener("first", (_:Event) -> {
			calls.push("adder");
			for (i in 0...12) {
				fresh.addEventListener("extra" + i, (_:Event) -> calls.push("extra"));
			}
		});
		fresh.addEventListener("first", (_:Event) -> calls.push("after"));
		fresh.dispatchEvent(new Event("first"));
		Assert.equals("adder,after", calls.join(","));
		calls = [];
		fresh.dispatchEvent(new Event("extra11"));
		Assert.equals("extra", calls.join(","));
	}

	#if (target.threaded && !eval)
	/**
		Two threads dispatching different types on one dispatcher, its
		listeners added beforehand: each thread's events reach its own type's
		listeners and only those, and are always found. Asking which listeners
		a type has must not write anything another thread's question can
		mix with its own: a remembered type and list, written one after the
		other, could be left holding one thread's type with the other's
		listeners, or with none.

		A test can only make the two threads overlap as much as it can, and
		on targets whose threads take turns it may never catch a lookup
		halfway; natively and on the jvm they run at once.
	**/
	public function testTwoThreadsDispatchingDifferentTypesReachOnlyTheirOwnListeners():Void {
		var dispatcher = new EventDispatcher();
		var strays:sys.thread.Deque<String> = new sys.thread.Deque();
		dispatcher.addEventListener("left", (event:Event) -> {
			if (event.type != "left") {
				strays.add(event.type + " reached left");
			}
		});
		dispatcher.addEventListener("right", (event:Event) -> {
			if (event.type != "right") {
				strays.add(event.type + " reached right");
			}
		});

		var rounds:Int = 200000;
		var start:sys.thread.Lock = new sys.thread.Lock();
		var results:sys.thread.Deque<Int> = new sys.thread.Deque();
		for (type in ["left", "right"]) {
			sys.thread.Thread.create(() -> {
				start.wait();
				var event = new Event(type);
				var missed:Int = 0;
				for (_ in 0...rounds) {
					event.reuse();
					if (!dispatcher.dispatchEvent(event)) {
						missed++;
					}
					if (!dispatcher.hasEventListener(type)) {
						missed++;
					}
				}
				results.add(missed);
			});
		}
		start.release();
		start.release();

		var missed:Int = 0;
		var deadline:Float = haxe.Timer.stamp() + 60;
		for (_ in 0...2) {
			var count:Null<Int> = null;
			while (count == null && haxe.Timer.stamp() < deadline) {
				count = results.pop(false);
				if (count == null) {
					crossbyte.sys.System.sleep(0.001);
				}
			}
			if (count == null) {
				Assert.fail("a dispatching thread did not finish within 60 s");
				return;
			}
			missed += count;
		}

		var stray:Null<String> = strays.pop(false);
		var strayCount:Int = 0;
		var first:Null<String> = stray;
		while (stray != null) {
			strayCount++;
			stray = strays.pop(false);
		}
		Assert.equals(0, strayCount, strayCount + " events reached another type's listeners, the first: " + first);
		Assert.equals(0, missed, "a type with listeners was found to have none " + missed + " times");
	}
	#end

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

	public var events(get, never):emitter.Events;

	public function addEventListener<T:emitter.Event>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		dispatcher.addEventListener(type, listener, priority);
	}

	function get_events():emitter.Events {
		return dispatcher.events;
	}
}

private class FailureRecorder extends EventDispatcher {
	public var failures:Array<Dynamic> = [];

	public function new() {
		super();
	}

	override private function listenerThrew(error:haxe.Exception, event:emitter.Event):Void {
		failures.push(@:privateAccess error.unwrap());
	}
}

/** A dispatcher with members of its own named as Emitter's words are. **/
private class OwnNames extends EventDispatcher {
	public var cleared:Int = 0;

	public function new() {
		super();
	}

	public function dispatch(type:String):Bool {
		return dispatchEvent(new Event(type));
	}

	public function clear():Void {
		cleared++;
	}
}
