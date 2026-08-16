package crossbyte.metrics;

#if (cpp || neko || hl || java || jvm)
import sys.thread.Mutex;
#end

/**
 * A value that can rise and fall, such as active connections, pool
 * capacity in use, or queue depth.
 *
 * A gauge may be driven by explicit `set`/`inc`/`dec` calls, or bound to a
 * provider function with `Metrics.gaugeFn`, in which case it is sampled at
 * read time. Binding is usually better for values another component
 * already tracks, since it cannot drift out of sync with the source.
 *
 * Safe to update from any thread.
 */
class Gauge {
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
	@:noCompletion private var __provider:Void->Float;

	#if (cpp || neko || hl || java || jvm)
	@:noCompletion private var __lock:Mutex;
	#end

	@:allow(crossbyte.metrics.Metrics)
	private function new(name:String, ?labels:Map<String, String>, ?help:String, ?provider:Void->Float) {
		this.name = name;
		this.labels = (labels == null) ? new Map() : labels;
		this.help = help;
		this.__provider = provider;

		#if (cpp || neko || hl || java || jvm)
		__lock = new Mutex();
		#end
	}

	/**
	 * Whether this gauge samples a provider function rather than holding a
	 * value of its own. Bound gauges ignore `set`, `inc`, and `dec`.
	 */
	public var bound(get, never):Bool;

	private function get_bound():Bool {
		return __provider != null;
	}

	/**
	 * Sets the current value. No effect on a bound gauge.
	 */
	public function set(value:Float):Void {
		if (__provider != null) {
			return;
		}

		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		__value = value;
		__lock.release();
		#else
		__value = value;
		#end
	}

	/**
	 * Adds `amount` to the current value. No effect on a bound gauge.
	 */
	public function inc(amount:Float = 1):Void {
		if (__provider != null) {
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
	 * Subtracts `amount` from the current value. No effect on a bound
	 * gauge.
	 */
	public function dec(amount:Float = 1):Void {
		inc(-amount);
	}

	/**
	 * The current value, sampling the provider when bound.
	 *
	 * A provider that throws yields `0` rather than propagating: scraping
	 * metrics must not be able to fail a request path.
	 */
	public function value():Float {
		if (__provider != null) {
			try {
				return __provider();
			} catch (_:Dynamic) {
				return 0;
			}
		}

		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		var snapshot:Float = __value;
		__lock.release();
		return snapshot;
		#else
		return __value;
		#end
	}
}
