package crossbyte.metrics;

import crossbyte.errors.ArgumentError;
#if (cpp || neko || hl || java || jvm)
#if (js && !nodejs)
import crossbyte._internal.js.NoMutex as Mutex;
#else
import sys.thread.Mutex;
#end
#end

/**
 * A distribution of observed values, such as request latency or payload
 * size, recorded into cumulative buckets.
 *
 * A histogram answers "how many observations fell at or below this
 * threshold", which supports latency objectives ("99% under 500 ms") that
 * an average would hide. Buckets are chosen up front and fixed, so cost
 * stays constant regardless of how many observations arrive.
 *
 * Safe to observe from any thread.
 */
class Histogram {
	/**
	 * Buckets suited to request latency in seconds.
	 */
	public static var DEFAULT_BUCKETS(default, never):Array<Float> = [
		0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0
	];

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

	/**
	 * Upper bounds of each bucket, ascending. An implicit `+Inf` bucket
	 * always exists and equals `count()`.
	 */
	public var bounds(default, null):Array<Float>;

	@:noCompletion private var __counts:Array<Float>;
	@:noCompletion private var __sum:Float = 0;
	@:noCompletion private var __count:Float = 0;

	#if (cpp || neko || hl || java || jvm)
	@:noCompletion private var __lock:Mutex;
	#end

	@:allow(crossbyte.metrics.Metrics)
	private function new(name:String, ?bounds:Array<Float>, ?labels:Map<String, String>, ?help:String) {
		this.name = name;
		this.labels = (labels == null) ? new Map() : labels;
		this.help = help;

		var chosen:Array<Float> = (bounds == null || bounds.length == 0) ? DEFAULT_BUCKETS.copy() : bounds.copy();
		chosen.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));

		for (i in 1...chosen.length) {
			if (chosen[i] == chosen[i - 1]) {
				throw new ArgumentError('Histogram "$name" has duplicate bucket bound ${chosen[i]}.');
			}
		}

		this.bounds = chosen;
		__counts = [for (_ in 0...chosen.length) 0.0];

		#if (cpp || neko || hl || java || jvm)
		__lock = new Mutex();
		#end
	}

	/**
	 * Records one observation.
	 */
	public function observe(value:Float):Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		#end

		__count++;
		__sum += value;
		for (i in 0...bounds.length) {
			if (value <= bounds[i]) {
				__counts[i]++;
			}
		}

		#if (cpp || neko || hl || java || jvm)
		__lock.release();
		#end
	}

	/**
	 * Times `body`, recording its duration in seconds, and returns its
	 * result. The observation is recorded even when `body` throws, so a
	 * failing path still contributes to the latency picture.
	 */
	public function time<T>(body:Void->T):T {
		var started:Float = haxe.Timer.stamp();

		try {
			var result:T = body();
			observe(haxe.Timer.stamp() - started);
			return result;
		} catch (e:Dynamic) {
			observe(haxe.Timer.stamp() - started);
			#if cpp
			cpp.Lib.rethrow(e);
			#else
			throw e;
			#end
			return null;
		}
	}

	/**
	 * Total number of observations.
	 */
	public function count():Float {
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		var snapshot:Float = __count;
		__lock.release();
		return snapshot;
		#else
		return __count;
		#end
	}

	/**
	 * Sum of all observed values.
	 */
	public function sum():Float {
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		var snapshot:Float = __sum;
		__lock.release();
		return snapshot;
		#else
		return __sum;
		#end
	}

	/**
	 * Cumulative counts, one per entry in `bounds`: each is the number of
	 * observations at or below that bound.
	 */
	public function bucketCounts():Array<Float> {
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		var snapshot:Array<Float> = __counts.copy();
		__lock.release();
		return snapshot;
		#else
		return __counts.copy();
		#end
	}
}
