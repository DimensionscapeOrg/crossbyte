package crossbyte._internal.socket;

#if ((cpp || jvm) && !macro)
import haxe.io.BytesData;

/**
	Storage for a runtime's large socket buffers, by size: what a buffer
	grown past 64 KB had, given back when it empties, and taken again by the
	next buffer that grows that far. A connection sending or receiving a
	megabyte a pass grew its output or input from nothing to past a megabyte
	every time it drained, allocating about three times what it carried;
	with the pool it takes the storage it gave back. Socket and WebSocket
	output and input take from it, and a WebSocket session's message buffer.

	Sizes run from 64 KB to 32 MB, four to each doubling (64, 80, 96, 112
	and 128 KB, and so on to 32 MB), so storage is at most a quarter larger
	than what it was taken for, where powers of two alone left a 9 MB
	backlog in 16 MB; jemalloc spaces its sizes the same way. A buffer
	larger than that grows as before. A buffer that gives back what it grew
	to takes 64 KB of the pool's for its next burst, which it gives back in
	turn when it grows past it, so a burst after the first allocates
	nothing; and it takes at once the size it held at most in its last
	burst (`takeFor`), so a burst like the last neither copies itself
	through every size below that nor leaves the pool holding each.

	How much is kept: while storage is being taken, of each size as much as
	was out at once since the registry last asked (`QuietRelease`, every five
	seconds). What an interval did not need waits one interval more as
	spare, taken before new storage is made, and goes if it is still unused
	at the next ask, as Go's `sync.Pool` keeps a victim generation. Netty's
	pooled buffers hold transient storage the same way.

	One runtime's, used on its thread only.
**/
@:noCompletion
class StoragePool implements QuietRelease {
	/** The smallest size kept: what a buffer keeps while busy. **/
	public static inline var SMALLEST:Int = 64 * 1024;

	/** The largest size kept. **/
	public static inline var LARGEST:Int = 32 * 1024 * 1024;

	// Four sizes to each doubling: class 4k + j is (SMALLEST << k) times
	// 1 + j / 4, so nine doublings and LARGEST make 37.
	static inline var CLASSES:Int = 37;

	@:noCompletion private var __idle:Array<Array<BytesData>> = [for (_ in 0...CLASSES) []];
	// Of each size, what went unused for a whole interval: freed if still
	// unused at the next ask.
	@:noCompletion private var __spare:Array<Array<BytesData>> = [for (_ in 0...CLASSES) []];
	@:noCompletion private var __out:Array<Int> = [for (_ in 0...CLASSES) 0];
	@:noCompletion private var __peak:Array<Int> = [for (_ in 0...CLASSES) 0];
	@:noCompletion private var __taken:Bool = false;
	@:noCompletion private var __watched:Bool = false;
	@:noCompletion private var __registry:Null<#if cpp NativeSocketRegistry #else SocketRegistry #end>;

	/** How many pieces of storage the pool has made, rather than handed out again. **/
	public var made(default, null):Int = 0;

	public function new(registry:Null<#if cpp NativeSocketRegistry #else SocketRegistry #end>) {
		__registry = registry;
	}

	/** The class kept for at least `needed` bytes, or -1 past the largest. **/
	static function __classFor(needed:Int):Int {
		if (needed <= SMALLEST) {
			return 0;
		}
		if (needed > LARGEST) {
			return -1;
		}
		// The doubling below `needed`, then how many of its quarters past it.
		var k:Int = 0;
		var base:Int = SMALLEST;
		while ((base << 1) < needed) {
			base <<= 1;
			k++;
		}
		var shift:Int = 14 + k;
		return (k << 2) + ((needed - base + (1 << shift) - 1) >> shift);
	}

	/** The size of class `c`. **/
	static inline function __sizeOf(c:Int):Int {
		var base:Int = SMALLEST << (c >> 2);
		return base + (base >> 2) * (c & 3);
	}

	/** The size kept for at least `needed` bytes, or -1 past the largest. **/
	public static function sizeFor(needed:Int):Int {
		var c:Int = __classFor(needed);
		return c < 0 ? -1 : __sizeOf(c);
	}

	/** Storage of at least `needed` bytes, kept or new; null past the largest size, which grows as it would without a pool. **/
	public function take(needed:Int):Null<BytesData> {
		var k:Int = __classFor(needed);
		if (k < 0) {
			return null;
		}
		__taken = true;
		var data:Null<BytesData> = __idle[k].pop();
		if (data == null) {
			data = __spare[k].pop();
		}
		if (data == null) {
			data = haxe.io.Bytes.alloc(__sizeOf(k)).getData();
			made++;
		}
		var out:Int = ++__out[k];
		if (out > __peak[k]) {
			__peak[k] = out;
		}
		return data;
	}

	/**
		As `take`, but for `hint` bytes where that is more and a size the pool
		keeps: what the buffer taking it held at most in its last burst, so a
		burst like the last takes its size at once rather than growing
		through every size below it.
	**/
	public inline function takeFor(needed:Int, hint:Int):Null<BytesData> {
		return take(hint > needed && hint <= LARGEST ? hint : needed);
	}

	/**
		`data` back, once the buffer that had it has let go of it. Storage
		of a size the pool does not keep is left to the collector.
	**/
	public function give(data:BytesData):Void {
		var capacity:Int = data.length;
		var k:Int = __classFor(capacity);
		if (k < 0 || __sizeOf(k) != capacity) {
			return;
		}
		if (__out[k] > 0) {
			__out[k]--;
		}
		__idle[k].push(data);
		if (!__watched && __registry != null) {
			__watched = true;
			__registry.watchQuiet(this);
		}
	}

	/**
		`data` back from a buffer that has grown out of it into larger storage
		from the pool: kept only as spare, taken before new storage is made
		and let go of at the next ask if nobody has. A buffer growing a size
		at a time passes through every size below what it needs, and, unlike
		storage given back by a buffer that emptied, those are not what its
		next burst will take (see `takeFor`). The smallest size, which every
		busy buffer keeps, is kept as `give` keeps it.
	**/
	public function giveGrown(data:BytesData):Void {
		var capacity:Int = data.length;
		var k:Int = __classFor(capacity);
		if (k < 0 || __sizeOf(k) != capacity) {
			return;
		}
		if (k == 0) {
			give(data);
			return;
		}
		if (__out[k] > 0) {
			__out[k]--;
		}
		__spare[k].push(data);
		if (!__watched && __registry != null) {
			__watched = true;
			__registry.watchQuiet(this);
		}
	}

	/** Bytes of storage the pool holds, not out. **/
	public function held():Float {
		var total:Float = 0;
		for (k in 0...CLASSES) {
			// In Float before the product, which in Int wraps from 64 of the
			// largest size up.
			total += (__idle[k].length + __spare[k].length) * 1.0 * __sizeOf(k);
		}
		return total;
	}

	/**
		Asked by the registry every few seconds: lets go of the spare storage
		left from the ask before, and makes spare what this interval did not
		need, all of it once nothing was taken. Whether to go on asking.
	**/
	public function __releaseIfQuiet():Bool {
		var holding:Bool = false;
		for (k in 0...CLASSES) {
			__spare[k].resize(0);
			var keep:Int = __taken ? __peak[k] - __out[k] : 0;
			if (keep < 0) {
				keep = 0;
			}
			var idle:Array<BytesData> = __idle[k];
			while (idle.length > keep) {
				__spare[k].push(idle.pop());
			}
			__peak[k] = __out[k];
			if (idle.length > 0 || __spare[k].length > 0) {
				holding = true;
			}
		}
		__taken = false;
		if (!holding) {
			__watched = false;
		}
		return holding;
	}
}
#end
