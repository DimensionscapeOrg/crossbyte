package crossbyte.metrics;

import crossbyte.errors.ArgumentError;
#if cpp
import crossbyte.metrics._internal.AtomicFloats;
#elseif target.threaded
import sys.thread.Mutex;
#end

/**
 * A monotonically increasing total, such as requests served or bytes sent.
 *
 * Counters only ever go up, which is what lets a collector compute a rate
 * from two samples and detect a process restart when the value drops.
 * Anything that can decrease is a `Gauge`.
 *
 * Safe to increment from any thread. On hxcpp an increment is an atomic
 * compare-and-swap rather than a lock.
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

	#if cpp
	// The total, as the one element of an array: it is updated in place with
	// atomic instructions, which AtomicFloats does to array elements. A lock
	// cost every increment about 230ns here, since acquiring an hxcpp Mutex
	// enters and leaves a GC-free zone.
	@:noCompletion private var __cells:Array<Float> = [0.0];
	#else
	@:noCompletion private var __value:Float = 0;
	#end

	#if (target.threaded && !cpp)
	@:noCompletion private var __lock:Mutex;
	#end

	@:allow(crossbyte.metrics.Metrics)
	private function new(name:String, ?labels:Map<String, String>, ?help:String) {
		this.name = name;
		this.labels = (labels == null) ? new Map() : labels;
		this.help = help;

		#if (target.threaded && !cpp)
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

		#if cpp
		AtomicFloats.add(__cells, 0, amount);
		#elseif target.threaded
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
		#if cpp
		return AtomicFloats.load(__cells, 0);
		#elseif target.threaded
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
		#if cpp
		AtomicFloats.store(__cells, 0, 0);
		#elseif target.threaded
		__lock.acquire();
		__value = 0;
		__lock.release();
		#else
		__value = 0;
		#end
	}
}
