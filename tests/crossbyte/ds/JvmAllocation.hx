package crossbyte.ds;

#if jvm
/**
	Bytes allocated by the calling thread, from the jvm's own per-thread
	counter (HotSpot's, and Temurin's), which counts every allocation
	exactly, so a case can assert that a path allocates nothing, where a
	heap-size delta on another target could only say roughly how much.
**/
class JvmAllocation {
	/**
		What running `f` allocated on this thread, less what reading the
		counter costs: the least of three runs, so a one-off (a class
		loading, a JIT deoptimisation) is not counted against it.
	**/
	public static function bytesBy(f:Void->Void):Float {
		var bean = java.lang.management.ManagementFactory.getThreadMXBean();
		var method = java.lang.Class.forName("com.sun.management.ThreadMXBean").getMethod("getThreadAllocatedBytes", java.lang.Long.TYPE);
		var thread = java.lang.Long.valueOf(java.lang.Thread.currentThread().getId());
		function read():Float {
			var bytes:Dynamic = method.invoke(bean, thread);
			return (bytes : Float);
		}
		var cost:Float = 1e18;
		for (_ in 0...5) {
			var a:Float = read();
			var b:Float = read();
			if (b - a < cost) {
				cost = b - a;
			}
		}
		var best:Float = 1e18;
		for (_ in 0...3) {
			var before:Float = read();
			f();
			var used:Float = read() - before - cost;
			if (used < best) {
				best = used;
			}
		}
		return best;
	}
}
#end
