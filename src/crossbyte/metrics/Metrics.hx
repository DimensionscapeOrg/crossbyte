package crossbyte.metrics;

import crossbyte.errors.ArgumentError;
#if (cpp || neko || hl || java || jvm)
import sys.thread.Mutex;
#end

/**
 * A registry of metrics a service publishes.
 *
 * ```haxe
 * var requests = Metrics.shared.counter("http_requests_total");
 * var latency = Metrics.shared.histogram("http_request_seconds");
 *
 * requests.inc();
 * latency.time(() -> handleRequest());
 *
 * // Serve from a status endpoint
 * response.write(Metrics.shared.toPrometheus());
 * ```
 *
 * Lookups return the same instance for the same name and labels, so
 * components can fetch a metric wherever they need it instead of passing
 * handles around.
 *
 * Gauges may instead be **bound** to a function, which suits values another
 * component already tracks:
 *
 * ```haxe
 * Metrics.shared.gaugeFn("db_pool_in_use", () -> pool.inUse());
 * ```
 *
 * **Cardinality and privacy.** Every distinct label combination creates a
 * separate series held for the process's lifetime. Labels must be
 * low-cardinality and describe categories — a route template, a status
 * class, an outcome. Never label with user identifiers, session tokens,
 * paths containing identifiers, or anything else per-user: doing so grows
 * memory without bound and turns an operational metric into a record of
 * individual behavior.
 */
class Metrics {
	/**
	 * The process-wide registry. Services may create their own instances
	 * instead when isolation is wanted, such as in tests.
	 */
	public static var shared(get, never):Metrics;

	@:noCompletion private static var __shared:Metrics;

	@:noCompletion private static function get_shared():Metrics {
		if (__shared == null) {
			__shared = new Metrics();
		}
		return __shared;
	}

	// Prometheus restricts names to [a-zA-Z_:][a-zA-Z0-9_:]* and labels to
	// [a-zA-Z_][a-zA-Z0-9_]*. Enforcing it here means a metric cannot be
	// created that an exporter would later have to mangle or drop.
	//
	// Validated by character rather than EReg deliberately: EReg carries
	// mutable match state, so a shared static instance is a data race when
	// metrics are fetched from several threads -- which shows up as valid
	// names being spuriously rejected under load.

	@:noCompletion private var __counters:Map<String, Counter>;
	@:noCompletion private var __gauges:Map<String, Gauge>;
	@:noCompletion private var __histograms:Map<String, Histogram>;
	@:noCompletion private var __order:Array<String>;

	#if (cpp || neko || hl || java || jvm)
	@:noCompletion private var __lock:Mutex;
	#end

	public function new() {
		__counters = new Map();
		__gauges = new Map();
		__histograms = new Map();
		__order = [];

		#if (cpp || neko || hl || java || jvm)
		__lock = new Mutex();
		#end
	}

	/**
	 * Returns the counter for `name` and `labels`, creating it if needed.
	 */
	public function counter(name:String, ?labels:Map<String, String>, ?help:String):Counter {
		__validate(name, labels);
		var key:String = __key(name, labels);

		__acquireLock();
		var existing:Counter = __counters.get(key);
		if (existing == null) {
			existing = new Counter(name, labels, help);
			__counters.set(key, existing);
			__order.push(key);
		}
		__releaseLock();

		return existing;
	}

	/**
	 * Returns the gauge for `name` and `labels`, creating it if needed.
	 */
	public function gauge(name:String, ?labels:Map<String, String>, ?help:String):Gauge {
		return __gauge(name, labels, help, null);
	}

	/**
	 * Returns a gauge that samples `provider` on read.
	 *
	 * If a gauge already exists under this name and labels it is returned
	 * unchanged, so repeated binding at startup is harmless.
	 */
	public function gaugeFn(name:String, provider:Void->Float, ?labels:Map<String, String>, ?help:String):Gauge {
		if (provider == null) {
			throw new ArgumentError("gaugeFn requires a provider.");
		}
		return __gauge(name, labels, help, provider);
	}

	/**
	 * Returns the histogram for `name` and `labels`, creating it if needed.
	 *
	 * @param bounds Bucket upper bounds. Ignored if the histogram already
	 *        exists; buckets cannot change once observations are recorded.
	 */
	public function histogram(name:String, ?bounds:Array<Float>, ?labels:Map<String, String>, ?help:String):Histogram {
		__validate(name, labels);
		var key:String = __key(name, labels);

		__acquireLock();
		var existing:Histogram = __histograms.get(key);
		if (existing == null) {
			existing = new Histogram(name, bounds, labels, help);
			__histograms.set(key, existing);
			__order.push(key);
		}
		__releaseLock();

		return existing;
	}

	/**
	 * Number of registered series across all metric types.
	 */
	public function size():Int {
		__acquireLock();
		var value:Int = __order.length;
		__releaseLock();
		return value;
	}

	/**
	 * Removes every registered metric. Intended for tests.
	 */
	public function clear():Void {
		__acquireLock();
		__counters = new Map();
		__gauges = new Map();
		__histograms = new Map();
		__order = [];
		__releaseLock();
	}

	/**
	 * Renders every metric in Prometheus text exposition format.
	 *
	 * The output is plain text suitable for an HTTP endpoint; serve it with
	 * content type `text/plain; version=0.0.4`.
	 */
	public function toPrometheus():String {
		__acquireLock();
		var keys:Array<String> = __order.copy();
		var counters = __counters;
		var gauges = __gauges;
		var histograms = __histograms;
		__releaseLock();

		var buffer = new StringBuf();
		// One HELP/TYPE header per metric name, even when several series
		// share it under different labels.
		var described:Map<String, Bool> = new Map();

		for (key in keys) {
			var counter:Counter = counters.get(key);
			if (counter != null) {
				__describe(buffer, described, counter.name, "counter", counter.help);
				__writeSample(buffer, counter.name, counter.labels, counter.value());
				continue;
			}

			var gauge:Gauge = gauges.get(key);
			if (gauge != null) {
				__describe(buffer, described, gauge.name, "gauge", gauge.help);
				__writeSample(buffer, gauge.name, gauge.labels, gauge.value());
				continue;
			}

			var histogram:Histogram = histograms.get(key);
			if (histogram != null) {
				__describe(buffer, described, histogram.name, "histogram", histogram.help);

				var counts:Array<Float> = histogram.bucketCounts();
				for (i in 0...histogram.bounds.length) {
					__writeSample(buffer, histogram.name + "_bucket", __withLabel(histogram.labels, "le", __number(histogram.bounds[i])), counts[i]);
				}
				__writeSample(buffer, histogram.name + "_bucket", __withLabel(histogram.labels, "le", "+Inf"), histogram.count());
				__writeSample(buffer, histogram.name + "_sum", histogram.labels, histogram.sum());
				__writeSample(buffer, histogram.name + "_count", histogram.labels, histogram.count());
			}
		}

		return buffer.toString();
	}

	@:noCompletion private function __gauge(name:String, labels:Map<String, String>, help:String, provider:Void->Float):Gauge {
		__validate(name, labels);
		var key:String = __key(name, labels);

		__acquireLock();
		var existing:Gauge = __gauges.get(key);
		if (existing == null) {
			existing = new Gauge(name, labels, help, provider);
			__gauges.set(key, existing);
			__order.push(key);
		}
		__releaseLock();

		return existing;
	}

	@:noCompletion private static function __describe(buffer:StringBuf, described:Map<String, Bool>, name:String, type:String, help:String):Void {
		if (described.exists(name)) {
			return;
		}
		described.set(name, true);

		if (help != null && help != "") {
			buffer.add("# HELP ");
			buffer.add(name);
			buffer.add(" ");
			buffer.add(__escapeHelp(help));
			buffer.add("\n");
		}

		buffer.add("# TYPE ");
		buffer.add(name);
		buffer.add(" ");
		buffer.add(type);
		buffer.add("\n");
	}

	@:noCompletion private static function __writeSample(buffer:StringBuf, name:String, labels:Map<String, String>, value:Float):Void {
		buffer.add(name);

		var names:Array<String> = [for (label in labels.keys()) label];
		if (names.length > 0) {
			// Sorted so a series renders identically across scrapes,
			// which keeps diffs and golden tests stable.
			names.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));

			buffer.add("{");
			for (i in 0...names.length) {
				if (i > 0) {
					buffer.add(",");
				}
				buffer.add(names[i]);
				buffer.add('="');
				buffer.add(__escapeLabel(labels.get(names[i])));
				buffer.add('"');
			}
			buffer.add("}");
		}

		buffer.add(" ");
		buffer.add(__number(value));
		buffer.add("\n");
	}

	@:noCompletion private static function __withLabel(labels:Map<String, String>, name:String, value:String):Map<String, String> {
		var merged:Map<String, String> = new Map();
		for (key => existing in labels) {
			merged.set(key, existing);
		}
		merged.set(name, value);
		return merged;
	}

	@:noCompletion private static function __number(value:Float):String {
		if (Math.isNaN(value)) {
			return "NaN";
		}
		if (!Math.isFinite(value)) {
			return value > 0 ? "+Inf" : "-Inf";
		}
		// Whole numbers render without a decimal point so counters read
		// naturally.
		if (value == Math.ffloor(value) && Math.abs(value) < 1e15) {
			return Std.string(Std.int(value));
		}
		return Std.string(value);
	}

	@:noCompletion private static function __escapeLabel(value:String):String {
		if (value == null) {
			return "";
		}
		var escaped:String = StringTools.replace(value, "\\", "\\\\");
		escaped = StringTools.replace(escaped, '"', '\\"');
		return StringTools.replace(escaped, "\n", "\\n");
	}

	@:noCompletion private static function __escapeHelp(value:String):String {
		var escaped:String = StringTools.replace(value, "\\", "\\\\");
		return StringTools.replace(escaped, "\n", "\\n");
	}

	@:noCompletion private static function __validate(name:String, labels:Map<String, String>):Void {
		if (!__isIdentifier(name, true)) {
			throw new ArgumentError('Invalid metric name "$name": expected [a-zA-Z_:][a-zA-Z0-9_:]*');
		}

		if (labels == null) {
			return;
		}

		for (label in labels.keys()) {
			if (!__isIdentifier(label, false)) {
				throw new ArgumentError('Invalid metric label "$label" on "$name": expected [a-zA-Z_][a-zA-Z0-9_]*');
			}
		}
	}

	@:noCompletion private static function __isIdentifier(value:String, allowColon:Bool):Bool {
		if (value == null || value.length == 0) {
			return false;
		}

		for (i in 0...value.length) {
			var code:Int = value.charCodeAt(i);
			var letter:Bool = (code >= "a".code && code <= "z".code) || (code >= "A".code && code <= "Z".code) || code == "_".code
				|| (allowColon && code == ":".code);

			if (letter) {
				continue;
			}
			// Digits are legal everywhere except the first position.
			if (i > 0 && code >= "0".code && code <= "9".code) {
				continue;
			}
			return false;
		}

		return true;
	}

	@:noCompletion private static function __key(name:String, labels:Map<String, String>):String {
		if (labels == null) {
			return name;
		}

		var names:Array<String> = [for (label in labels.keys()) label];
		if (names.length == 0) {
			return name;
		}
		names.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));

		var buffer = new StringBuf();
		buffer.add(name);
		for (label in names) {
			buffer.add("");
			buffer.add(label);
			buffer.add("");
			buffer.add(labels.get(label));
		}
		return buffer.toString();
	}

	@:noCompletion private inline function __acquireLock():Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		#end
	}

	@:noCompletion private inline function __releaseLock():Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.release();
		#end
	}
}
