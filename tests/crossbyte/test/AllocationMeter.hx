package crossbyte.test;

/**
	Bytes allocated per operation, on the two targets that can say: natively
	and on the jvm. What is counted is what the measuring thread allocates;
	every operation measured here runs on it, both ends of a connection
	included.

	**On the jvm**, `com.sun.management.ThreadMXBean.getThreadAllocatedBytes`
	counts each thread's allocations exactly. What every other thread
	allocated during a run is reported beside it, as `background`.

	**Natively** hxcpp keeps no running total of what has been allocated, and
	the figure that looks like one is not: `MEM_INFO_CURRENT` adds a block's
	lines only when a thread takes the block on the collector's slow path,
	and a thread takes a free block on its fast path without counting it, so
	a run allocating 4 MB of 1,000-byte `Bytes` read 0. What does move with
	every allocation is the thread's own allocator: an object is carved from
	the current hole of the current block by moving `spaceStart` forward by
	its size, header and alignment. So the meter reads that cursor after each
	operation, with collection switched off, and an operation that started
	and ended in the same hole allocated exactly the distance it moved. One
	that moved on to another hole or block is not counted, and the rest are
	averaged: what one operation allocates is the same from one to the next,
	so leaving out the ones that happened to cross a boundary does not change
	the figure. An object of 4,000 bytes or more is allocated apart from the
	blocks, and the collector does keep that total, `MEM_INFO_LARGE`, exactly;
	the large bytes of a run are added over the whole run. That total is the
	process's, so an idle window after each run says how much of it other
	threads allocated, as `background`.

	Node, neko, hl and the interpreter have no counter to read, and nothing
	here runs there.
**/
class AllocationMeter {
	/** Whether this target has a counter to measure with. **/
	public static inline var SUPPORTED:Bool = #if (cpp || jvm) true #else false #end;

	/** The longest idle window after a native run. **/
	private static inline var IDLE_PROBE_SECONDS:Float = 0.02;

	/**
		Runs `op` `count` times in each of `rounds` runs and reads what each
		run allocated per call to `op`: the median of the runs, with every
		run kept in `samples`.

		Warm the path up first: the first calls of anything allocate what
		the rest reuse, and the jvm compiles it only after a few thousand.
	**/
	public static function measure(op:Void->Void, count:Int, rounds:Int = 3):AllocationReading {
		var samples:Array<Float> = [];
		var times:Array<Float> = [];
		var background:Float = 0.0;
		var counted:Float = 1.0;

		for (_ in 0...rounds) {
			var run:Run = __run(op, count);
			samples.push(run.perOperation);
			times.push(run.seconds / count);
			if (run.background > background) {
				background = run.background;
			}
			if (run.counted < counted) {
				counted = run.counted;
			}
		}

		return new AllocationReading(__median(samples), samples, count, background, counted, __median(times));
	}

	private static function __median(values:Array<Float>):Float {
		var sorted:Array<Float> = values.copy();
		sorted.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return sorted[sorted.length >> 1];
	}

	/**
		Which platform's budget applies here: `"windows"`, `"linux"` or
		`"mac"` natively, `"jvm"` on the jvm, and `null` where nothing is
		measured.
	**/
	public static function platform():Null<String> {
		#if cpp
		return switch (Sys.systemName()) {
			case "Windows": "windows";
			case "Mac": "mac";
			default: "linux";
		}
		#elseif jvm
		return "jvm";
		#else
		return null;
		#end
	}

	private static function __run(op:Void->Void, count:Int):Run {
		#if cpp
		// A heap the suite has fragmented leaves small holes, which more of the
		// operations cross: in the full suite a fifth to a third of them are
		// counted, against nine in ten alone. Too few to trust is run again,
		// on the holes the next collection leaves.
		var run:Run = null;
		for (_ in 0...5) {
			run = __nativeRun(op, count);
			if (run.counted * count >= MIN_COUNTED) {
				return run;
			}
		}
		throw "only " + Math.round(run.counted * count) + " of " + count
			+ " operations started and ended in the same hole of the collector's blocks, five times over, which is too few to measure by";
		#elseif jvm
		var bean:AllocatingThreadBean = cast java.lang.management.ManagementFactory.getThreadMXBean();
		var self:haxe.Int64 = java.lang.Thread.currentThread().getId();
		// What one reading costs this thread: JDK 8 builds two arrays for it.
		var cost:Float = __long(bean.getThreadAllocatedBytes(self));
		cost = __long(bean.getThreadAllocatedBytes(self)) - cost;

		var othersBefore:Float = __others(bean, self);
		var before:Float = __long(bean.getThreadAllocatedBytes(self));
		var started:Float = haxe.Timer.stamp();
		for (_ in 0...count) {
			op();
		}
		var took:Float = haxe.Timer.stamp() - started;
		var after:Float = __long(bean.getThreadAllocatedBytes(self));
		var othersAfter:Float = __others(bean, self);
		return new Run((after - before - cost) / count, (othersAfter - othersBefore) / count, 1.0, took);
		#else
		var started:Float = haxe.Timer.stamp();
		for (_ in 0...count) {
			op();
		}
		return new Run(0.0, 0.0, 1.0, haxe.Timer.stamp() - started);
		#end
	}

	#if cpp
	/** Operations a native run counts at least, or it is run again. **/
	private static inline var MIN_COUNTED:Int = 50;

	private static function __nativeRun(op:Void->Void, count:Int):Run {
		// Collected first, so the run starts in fresh holes, and not again
		// until it is read: a collection resets the thread's allocator and
		// frees the large objects counted.
		cpp.vm.Gc.run(true);
		cpp.vm.Gc.enable(false);
		var small:Float = 0.0;
		var counted:Int = 0;
		var large:Float = 0.0;
		var background:Float = 0.0;
		var took:Float = 0.0;
		try {
			var largeBefore:Float = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_LARGE);
			var started:Float = haxe.Timer.stamp();
			var block:Float = __block();
			var end:Float = __holeEnd();
			var at:Float = __cursor();
			for (_ in 0...count) {
				op();
				var nowBlock:Float = __block();
				var nowEnd:Float = __holeEnd();
				var nowAt:Float = __cursor();
				if (nowBlock == block && nowEnd == end && nowAt >= at) {
					small += nowAt - at;
					counted++;
				}
				block = nowBlock;
				end = nowEnd;
				at = nowAt;
			}
			took = haxe.Timer.stamp() - started;
			large = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_LARGE) - largeBefore;

			// What the rest of the process allocated large while this thread
			// slept, scaled to the run's length.
			var idle:Float = took < IDLE_PROBE_SECONDS ? took : IDLE_PROBE_SECONDS;
			var idleBefore:Float = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_LARGE);
			crossbyte.sys.System.sleep(idle);
			var idleAfter:Float = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_LARGE);
			background = idle > 0 ? (idleAfter - idleBefore) * (took / idle) / count : 0.0;
		} catch (error:Dynamic) {
			cpp.vm.Gc.enable(true);
			throw error;
		}
		cpp.vm.Gc.enable(true);
		return new Run(counted > 0 ? small / counted + large / count : 0.0, background, counted / count, took);
	}

	// The calling thread's allocator: the block it is carving objects from,
	// the end of the hole it is in, and how far into the block it has got.
	// An address fits a double exactly: x64 addresses are 48 bits.
	private static inline function __block():Float {
		return untyped __cpp__("(double)(size_t)(HX_CTX_GET->allocBase)");
	}

	private static inline function __holeEnd():Float {
		return untyped __cpp__("(double)(HX_CTX_GET->spaceEnd)");
	}

	private static inline function __cursor():Float {
		return untyped __cpp__("(double)(HX_CTX_GET->spaceStart)");
	}
	#end

	#if jvm
	/** What every thread but `self` has allocated, all told. **/
	private static function __others(bean:AllocatingThreadBean, self:haxe.Int64):Float {
		var ids:java.NativeArray<haxe.Int64> = bean.getAllThreadIds();
		var sizes:java.NativeArray<haxe.Int64> = bean.getThreadAllocatedBytes(ids);
		var total:Float = 0.0;
		for (i in 0...ids.length) {
			if (ids[i] != self && sizes[i] > 0) {
				total += __long(sizes[i]);
			}
		}
		return total;
	}

	private static inline function __long(value:haxe.Int64):Float {
		var low:Float = value.low;
		if (low < 0) {
			low += 4294967296.0;
		}
		return value.high * 4294967296.0 + low;
	}
	#end
}

/**
	What `AllocationMeter.measure` read: bytes per operation, the median of
	`samples`, over runs of `count`.
**/
class AllocationReading {
	public final perOperation:Float;
	public final samples:Array<Float>;
	public final count:Int;

	/**
		Bytes per operation other threads allocated during the worst run: on
		the jvm everything they allocated, natively their large objects,
		which `perOperation` cannot tell from this thread's.
	**/
	public final background:Float;

	/**
		Natively, the least share of a run's operations that stayed within one
		hole and so were counted; 1 on the jvm, which counts every one.
	**/
	public final counted:Float;

	/**
		Seconds each operation took, the median of the runs, measuring
		included: what a change to the path costs or saves in time, read
		beside what it allocates.
	**/
	public final secondsPerOperation:Float;

	public function new(perOperation:Float, samples:Array<Float>, count:Int, background:Float, counted:Float, secondsPerOperation:Float) {
		this.perOperation = perOperation;
		this.samples = samples;
		this.count = count;
		this.background = background;
		this.counted = counted;
		this.secondsPerOperation = secondsPerOperation;
	}

	public function toString():String {
		var runs:Array<String> = [for (sample in samples) Std.string(Math.round(sample))];
		return Math.round(perOperation) + " B (runs " + runs.join(" / ") + " of " + count + ", " + Math.round(counted * 100) + "% counted; other threads "
			+ Math.round(background) + " B; " + Math.round(secondsPerOperation * 1e9) + " ns each)";
	}
}

private class Run {
	public final perOperation:Float;
	public final background:Float;
	public final counted:Float;
	public final seconds:Float;

	public function new(perOperation:Float, background:Float, counted:Float, seconds:Float) {
		this.perOperation = perOperation;
		this.background = background;
		this.counted = counted;
		this.seconds = seconds;
	}
}

#if jvm
/**
	HotSpot's own thread bean, which every JDK this runs on (Temurin 8 in
	CI) has: it counts what each thread allocated.
**/
@:native("com.sun.management.ThreadMXBean")
private extern interface AllocatingThreadBean {
	overload function getThreadAllocatedBytes(id:haxe.Int64):haxe.Int64;
	overload function getThreadAllocatedBytes(ids:java.NativeArray<haxe.Int64>):java.NativeArray<haxe.Int64>;
	function getAllThreadIds():java.NativeArray<haxe.Int64>;
}
#end
