import crossbyte._internal.system.timer.heap.TimerHeap;
import crossbyte._internal.system.timer.wheel.TimerWheel;
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.TickEvent;

/**
	What the runtime's own loop costs per pass, with nothing going wrong: the
	timer schedulers firing and re-arming, a tick reaching its listeners, and a
	callback posted to the runtime and run by it.

	These are the paths a callback's failure is contained on. Containing it is
	meant to cost nothing until something actually throws, and these are where
	that claim is checked.
**/
@:access(crossbyte.core.CrossByte)
class BenchRuntime {
	public static function run():Void {
		Bench.section("Timers");

		// A thousand recurring timers all due on every pass: fire, re-arm,
		// sift. Reported per pass, so divide by 1000 for one timer.
		var heap = new TimerHeap();
		for (i in 0...1000) {
			heap.setIntervalVoid(0.001, 0.001, function():Void {});
		}
		Bench.run("heap: 1000 due, fire + re-arm", function():Void {
			heap.advanceTime(0.001, 1 << 28);
		});

		var wheel = new TimerWheel();
		for (i in 0...1000) {
			wheel.setIntervalVoid(0.001, 0.001, function():Void {});
		}
		Bench.run("wheel: 1000 due, fire + re-arm", function():Void {
			wheel.advanceTime(0.001, 1 << 28);
		});

		Bench.section("Loop");

		// One host-driven pass with nothing registered: the floor every frame
		// pays before it does anything.
		var idle = new CrossByte(false, DEFAULT, true);
		Bench.run("pump, nothing to do", function():Void {
			idle.pump(0.001, 0);
		});
		idle.exit();

		// Eight tick listeners, which is what a runtime serving a handful of
		// components carries.
		var busy = new CrossByte(false, DEFAULT, true);
		for (_ in 0...8) {
			busy.addEventListener(TickEvent.TICK, function(_:TickEvent):Void {});
		}
		Bench.run("pump, 8 tick listeners", function():Void {
			busy.pump(0.001, 0);
		});

		// A callback handed to the runtime and run on its next pass.
		var noop = function():Void {};
		Bench.run("post + pump", function():Void {
			busy.__post(noop);
			busy.pump(0.001, 0);
		});
		busy.exit();

		Bench.section("Listeners");

		// A thousand listeners on one type added and then removed, as a
		// thousand connections or tasks each attaching one would. Reported
		// per round, so divide by 2000 for one call. Removed in the order they
		// were added, and then in reverse, since the two find their entry at
		// opposite ends of the list.
		var dispatcher = new EventDispatcher();
		var listeners:Array<Event->Void> = [for (_ in 0...1000) function(_:Event):Void {}];
		Bench.run("1000 added, removed oldest first", function():Void {
			for (listener in listeners) {
				dispatcher.addEventListener("churn", listener);
			}
			for (listener in listeners) {
				dispatcher.removeEventListener("churn", listener);
			}
		});
		Bench.run("1000 added, removed newest first", function():Void {
			for (listener in listeners) {
				dispatcher.addEventListener("churn", listener);
			}
			var i = listeners.length;
			while (i-- > 0) {
				dispatcher.removeEventListener("churn", listeners[i]);
			}
		});
	}
}
