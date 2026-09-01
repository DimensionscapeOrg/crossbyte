/**
	A small fixed-methodology benchmark harness.

	Each case is calibrated until one sample takes long enough to measure, then
	timed several times, and the **best** sample is reported. Best rather than
	mean, deliberately: on a machine that is doing anything else, noise only
	ever adds time, so the fastest observation is the closest to what the code
	costs and the mean is a measurement of the machine's mood.

	Numbers from this are for comparing two shapes of the same code on the same
	machine in the same sitting. They are not service-level anything, and they
	are not comparable across machines or days -- which is why the CI run of
	this suite is informational and gates nothing.
**/
class Bench {
	/** How long one calibrated sample should take, in seconds. **/
	private static inline var TARGET_SAMPLE:Float = 0.1;

	/** Samples per case; the best one is reported. **/
	private static inline var SAMPLES:Int = 5;

	private static var __rows:Array<{name:String, nsPerOp:Float, throughput:String}> = [];

	private static var __section:String = "";

	public static function section(name:String):Void {
		__section = name;
	}

	/**
		Times one case.

		@param bytesPerOp When the case is byte-oriented, how many bytes one
		call handles; reported as MB/s alongside the per-call time.
	**/
	public static function run(name:String, fn:Void->Void, bytesPerOp:Int = 0):Void {
		// Calibration: double the rep count until a sample is long enough for
		// the clock's resolution to be irrelevant, then scale to the target.
		var reps = 1;

		while (true) {
			var t0 = Sys.time();

			for (_ in 0...reps) {
				fn();
			}

			var elapsed = Sys.time() - t0;

			if (elapsed >= 0.01) {
				reps = Std.int(Math.max(1, reps * TARGET_SAMPLE / elapsed));
				break;
			}

			reps *= 2;
		}

		var best = Math.POSITIVE_INFINITY;

		for (_ in 0...SAMPLES) {
			var t0 = Sys.time();

			for (_ in 0...reps) {
				fn();
			}

			var elapsed = Sys.time() - t0;

			if (elapsed < best) {
				best = elapsed;
			}
		}

		var nsPerOp = best / reps * 1e9;
		var throughput = bytesPerOp > 0 ? Math.round(bytesPerOp / (best / reps) / (1024 * 1024)) + " MB/s" : "";

		__rows.push({
			name: (__section != "" ? __section + "  " : "") + name,
			nsPerOp: nsPerOp,
			throughput: throughput
		});

		Sys.println("  " + pad((__section != "" ? __section + "  " : "") + name, 46) + pad(formatNs(nsPerOp), 12)
			+ (throughput != "" ? "  " + throughput : ""));
	}

	public static function header():Void {
		Sys.println("");
		Sys.println("  " + pad("case", 46) + pad("per op", 12));
		Sys.println("  " + pad("", 70, "-"));
	}

	private static function formatNs(ns:Float):String {
		if (ns >= 1e6) {
			return Math.round(ns / 1e4) / 100 + " ms";
		}

		if (ns >= 1e3) {
			return Math.round(ns / 10) / 100 + " us";
		}

		return Math.round(ns) + " ns";
	}

	private static function pad(text:String, width:Int, with:String = " "):String {
		var out = text;

		while (out.length < width) {
			out += with;
		}

		return out;
	}
}
