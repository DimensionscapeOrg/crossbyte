package crossbyte.metrics;

import crossbyte.errors.ArgumentError;
#if cpp
import crossbyte.metrics._internal.AtomicFloats;
#elseif (neko || hl || java || jvm)
import sys.thread.Mutex;
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
 * Safe to observe from any thread. On hxcpp an observation is two atomic
 * additions rather than a lock -- one to the bucket it falls in, one to the
 * sum -- so a read taken while observations arrive can find the sum
 * counting one that the buckets do not yet, or the other way round. The
 * buckets and the count always agree with each other: the count is the
 * total of the buckets, and the buckets never decrease from one bound to
 * the next.
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

	// One count per bound, of the observations that fell in that bucket and
	// no lower one; then the count of those above every bound; then the sum.
	//
	// Each observation adds to one bucket here rather than to every bucket
	// at or above it, and the cumulative counts and the total are added up
	// when read. That makes an observation two updates however many buckets
	// there are, where it was one per bucket it fell under: eleven for a
	// fast response under the default buckets. And it makes the count the
	// total of the buckets, so the two cannot disagree -- they were separate,
	// and a read between the updates saw a count the buckets did not add up
	// to.
	@:noCompletion private var __cells:Array<Float>;

	#if (neko || hl || java || jvm)
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
		__cells = [for (_ in 0...chosen.length + 2) 0.0];

		#if (neko || hl || java || jvm)
		__lock = new Mutex();
		#end
	}

	/**
	 * Records one observation.
	 */
	public function observe(value:Float):Void {
		// The first bucket whose bound it does not exceed, or the one past the
		// last. NaN is at or below no bound, so it lands there as well: in the
		// count and +Inf only, as it always was.
		//
		// Counted off the cells rather than off `bounds`, which is a public
		// array a caller can grow: on hxcpp the update below writes to memory
		// directly, and an index from `bounds` could then land past the end.
		var bucket:Int = 0;
		var last:Int = __cells.length - 2;
		while (bucket < last && !(value <= bounds[bucket])) {
			bucket++;
		}

		#if cpp
		AtomicFloats.add(__cells, bucket, 1);
		AtomicFloats.add(__cells, last + 1, value);
		#elseif (neko || hl || java || jvm)
		__lock.acquire();
		__cells[bucket] += 1;
		__cells[last + 1] += value;
		__lock.release();
		#else
		__cells[bucket] += 1;
		__cells[last + 1] += value;
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
		// Every bucket, and the one past the last bound: all but the sum.
		var buckets:Int = __cells.length - 1;
		var total:Float = 0;
		#if cpp
		for (i in 0...buckets) {
			total += AtomicFloats.load(__cells, i);
		}
		#elseif (neko || hl || java || jvm)
		__lock.acquire();
		for (i in 0...buckets) {
			total += __cells[i];
		}
		__lock.release();
		#else
		for (i in 0...buckets) {
			total += __cells[i];
		}
		#end
		return total;
	}

	/**
	 * Sum of all observed values.
	 */
	public function sum():Float {
		#if cpp
		return AtomicFloats.load(__cells, __cells.length - 1);
		#elseif (neko || hl || java || jvm)
		__lock.acquire();
		var snapshot:Float = __cells[__cells.length - 1];
		__lock.release();
		return snapshot;
		#else
		return __cells[__cells.length - 1];
		#end
	}

	/**
	 * Cumulative counts, one per entry in `bounds`: each is the number of
	 * observations at or below that bound.
	 */
	public function bucketCounts():Array<Float> {
		var snapshot:Array<Float> = __snapshot();
		snapshot.resize(snapshot.length - 2);
		return snapshot;
	}

	/**
	 * Everything the exposition writes, read in one pass: the cumulative
	 * count at each bound, then the total -- which is the `+Inf` bucket and
	 * `_count` both -- then the sum.
	 *
	 * One pass so that a scrape agrees with itself. The exposition used to
	 * read the buckets, the count and the sum separately, and an observation
	 * landing between two of those reads made `+Inf` and `_count` differ.
	 */
	@:allow(crossbyte.metrics.Metrics)
	@:noCompletion private function __snapshot():Array<Float> {
		#if cpp
		var cells:Array<Float> = [for (i in 0...__cells.length) AtomicFloats.load(__cells, i)];
		#elseif (neko || hl || java || jvm)
		__lock.acquire();
		var cells:Array<Float> = __cells.copy();
		__lock.release();
		#else
		var cells:Array<Float> = __cells.copy();
		#end

		// In place: each bucket's count becomes the running total up to it,
		// and the slot after the last bound -- the ones above every bound --
		// becomes the total of all of them. The sum, last, stays as it is.
		var running:Float = 0;
		for (i in 0...cells.length - 1) {
			running += cells[i];
			cells[i] = running;
		}
		return cells;
	}
}
