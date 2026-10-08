package crossbyte.test;

import utest.Runner;
import utest.ui.Report;

/**
	Builds a runtime and runs a suite against it.

	## If a run comes back red once and green after

	Capture rather than re-run: keep the whole output, and the failing names
	with it. Building with `-D test_trace` prints each fixture as it starts,
	which is what attributes a hang or a crash to a method when the report
	never gets printed at all.

	## Cornering an intermittent native crash

	Three flags, none of which do anything unless asked for, and the order to
	reach for them in.

	- `-D test_trace` names the fixture that was running. It names where the
	  collector ran, which is not the same as where the damage was done:
	  check any accusation it makes by reproducing that fixture alone.
	- `-D gc_probe` forces a major collection after every fixture. If the
	  crash stops happening, nothing is writing bad memory and the fault is
	  in what accumulates between collections.
	- `-D gc_bisect` makes the suite selectable at runtime, so narrowing it
	  costs a run rather than a rebuild. `CB_ONLY` is a comma separated list
	  of substrings matched against case class names, `CB_METHOD` a regex
	  over method names. A fault that is probabilistic stays probabilistic,
	  so a subset needs enough runs to mean something: roughly twenty for a
	  fault seen in one run of five.

	hxcpp has more of these: `HXCPP_GC_VERIFY`, `HXCPP_GC_CHECK_POINTER`,
	`HXCPP_GC_SUMMARY`. Read `src/hx/gc/Immix.cpp` before building an
	instrument by hand.

	One of them is a trap. `HXCPP_GC_DEBUG_ALWAYS_MOVE` looks like the answer,
	since it makes a fault deterministic, but `HXCPP_GC_MOVING` is commented
	out in `Immix.cpp`, so the shipping collector never moves anything and
	that flag switches on a code path the real build does not have: a crash it
	reproduces may be a different fault, in a configuration nobody ships.
	Check what a debug flag turns on, and confirm any reproduction against the
	plain build before believing it.
**/
@:access(crossbyte.core.CrossByte)
class TestHarness {
	public static function run(configure:Runner->Void):Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);

		#if gc_bisect
		var runner = new BisectRunner();
		runner.only = Sys.getEnv("CB_ONLY");
		#else
		var runner = new Runner();
		#end
		configure(runner);
		#if gc_bisect
		Sys.println("[BISECT] only=" + (runner.only == null ? "<everything>" : runner.only) + " kept=" + runner.kept);
		Sys.stdout().flush();
		#end
		#if test_trace
		// Build with `-D test_trace` to print each test as it starts. utest runs
		// fixtures in an order unrelated to registration, so when a native run
		// hangs this is the only way to attribute the hang to a method.
		runner.onTestStart.add(handler -> {
			var fixture = handler.fixture;
			Sys.println("[TEST] " + Type.getClassName(Type.getClass(fixture.target)) + "." + fixture.method);
			Sys.stdout().flush();
		});
		#end
		#if (gc_probe && cpp)
		// Build with `-D gc_probe` to force a major collection after every
		// fixture. A collector walking a heap something has already damaged
		// faults at the next collection, so with this the fixture named by the
		// last line before the fault is the last one that could have done it.
		runner.onTestComplete.add(handler -> {
			var fixture = handler.fixture;
			Sys.println("[GC] after " + Type.getClassName(Type.getClass(fixture.target)) + "." + fixture.method);
			Sys.stdout().flush();
			cpp.vm.Gc.run(true);
		});
		#end
		Report.create(runner);
		runner.run();
	}
}

#if gc_bisect
/**
	A runner that takes only the cases named, so the suite can be narrowed
	without rebuilding it.

	`CB_ONLY` is a comma separated list of substrings matched against each
	case's class name; anything else is dropped before it is registered.
**/
private class BisectRunner extends Runner {
	public var only:String = null;

	public var kept:Int = 0;

	override public function addCase(test:Dynamic, setup = "setup", teardown = "teardown", prefix = "test", ?pattern:EReg,
			setupAsync = "setupAsync", teardownAsync = "teardownAsync") {
		if (only != null && only != "") {
			var name = Type.getClassName(Type.getClass(test));
			var wanted = false;

			for (part in only.split(",")) {
				if (part != "" && name.indexOf(part) >= 0) {
					wanted = true;
					break;
				}
			}

			if (!wanted) {
				return;
			}
		}

		kept++;

		// utest already filters methods by regex; `CB_METHOD` just supplies
		// one, so a single fixture can be run without another build.
		var byMethod = Sys.getEnv("CB_METHOD");

		if (byMethod != null && byMethod != "") {
			super.addCase(test, setup, teardown, prefix, new EReg(byMethod, ""), setupAsync, teardownAsync);
			return;
		}

		super.addCase(test, setup, teardown, prefix, pattern, setupAsync, teardownAsync);
	}
}
#end
