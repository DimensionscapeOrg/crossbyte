package crossbyte.metrics;

import crossbyte.errors.ArgumentError;
#if (cpp || neko || hl || java || jvm)
import sys.thread.Mutex;
#end

/**
 * A monotonically increasing total, such as requests served or bytes sent.
 *
 * Counters only ever go up, which is what lets a collector compute a rate
 * from two samples and detect a process restart when the value drops.
 * Anything that can decrease is a `Gauge`.
 *
 * Safe to increment from any thread.
 */
class Counter {
	/**
	 * The metric name.
	 */
	public var name(default, null):String;

	/**
	 * Label pairs distinguishing this series from others of the same name.
	 */
	public var labels(default, null):Map<String, String>;

	/**
	 * Optional human-readable description used by exporters.
	 */
	public var help(default, null):String;

	@:noCompletion private var __value:Float = 0;

	#if (cpp || neko || hl || java || jvm)
	@:noCompletion private var __lock:Mutex;
	#end

	@:allow(crossbyte.metrics.Metrics)
	private function new(name:String, ?labels:Map<String, String>, ?help:String) {
		this.name = name;
		this.labels = (labels == null) ? new Map() : labels;
		this.help = help;

		#if (cpp || neko || hl || java || jvm)
		__lock = new Mutex();
		#end
	}

	/**
	 * Adds `amount` to the total.
	 *
	 * @param amount Must not be negative; a counter that can go down is a
	 *        gauge, and silently allowing it would corrupt every rate
	 *        computed from this series.
	 */
	public function inc(amount:Float = 1):Void {
		if (amount < 0) {
			throw new ArgumentError('Counter "$name" cannot decrease (got $amount); use a Gauge for values that go down.');
		}
		if (amount == 0) {
			return;
		}

		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		__value += amount;
		__lock.release();
		#else
		__value += amount;
		#end
	}

	/**
	 * The current total.
	 */
	public function value():Float {
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		var snapshot:Float = __value;
		__lock.release();
		return snapshot;
		#else
		return __value;
		#end
	}

	/**
	 * Resets the total to zero. Intended for tests; resetting a live
	 * counter makes a collector read it as a process restart.
	 */
	public function reset():Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		__value = 0;
		__lock.release();
		#else
		__value = 0;
		#end
	}
}
