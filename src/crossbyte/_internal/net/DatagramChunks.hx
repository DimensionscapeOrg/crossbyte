package crossbyte._internal.net;

#if cpp
import crossbyte._internal.socket.NativeSocketRegistry;
import crossbyte._internal.socket.QuietRelease;
import haxe.io.Bytes;

/**
	The chunks a runtime's datagram sockets gather a pass's sends in (see
	`DatagramSocket.__sendInPass`), one pool for every socket of the runtime.

	A chunk is 64 KB, more than the largest datagram UDP carries, and each
	datagram lies whole in one, so a pass of any size is a list of chunks
	that need not lie together: the batch send points each datagram's iovec
	into its own chunk. Chunks go back to the pool once the pass has sent
	them. This is how Netty's pooled buffers, nginx's buffer chains and Go's
	`sync.Pool` hold transient output: a burst takes what it needs, and a
	quiet runtime gives it back, rather than one buffer growing to twice the
	largest pass and keeping it for good.

	How much it keeps: every chunk while chunks are being taken, up to the
	most in use at once since the registry last asked (`QuietRelease`, every
	five seconds), so a server broadcasting every frame takes nothing new.
	What an interval did not need waits one interval more as spare, taken
	before a new chunk is made, and goes if it is still unused at the next
	ask, as Go's `sync.Pool` keeps a victim generation: a server pausing
	between matches takes its chunks back, and a quiet one is down to one
	chunk ten to fifteen seconds after its last burst.

	One runtime's, used on its thread only.
**/
@:noCompletion
class DatagramChunks implements QuietRelease {
	/** A chunk's size: past the largest datagram, 65,507 bytes over IPv4 and 65,527 over IPv6. **/
	public static inline var CHUNK_SIZE:Int = 65536;

	/** Chunks kept however quiet the runtime: one, for a socket's next small pass. **/
	public static inline var SPARE:Int = 1;

	@:noCompletion private var __idle:Array<Bytes> = [];
	// Chunks that went unused for a whole interval, freed if still unused at
	// the next ask; taken before a new one is made.
	@:noCompletion private var __spare:Array<Bytes> = [];
	@:noCompletion private var __inUse:Int = 0;
	// The most in use at once since the registry last asked, and whether any
	// was taken since then.
	@:noCompletion private var __peak:Int = 0;
	@:noCompletion private var __taken:Bool = false;
	@:noCompletion private var __watched:Bool = false;
	@:noCompletion private var __registry:Null<NativeSocketRegistry>;

	public function new(registry:Null<NativeSocketRegistry>) {
		__registry = registry;
	}

	/** Chunks not in use, kept for the next pass. **/
	public var idle(get, never):Int;

	/** Chunks a pass holds now. **/
	public var inUse(get, never):Int;

	private inline function get_idle():Int {
		return __idle.length + __spare.length;
	}

	private inline function get_inUse():Int {
		return __inUse;
	}

	/** A chunk for a pass: one kept, or a new one. **/
	public function take():Bytes {
		__taken = true;
		var chunk:Null<Bytes> = __idle.pop();
		if (chunk == null) {
			chunk = __spare.pop();
		}
		if (chunk == null) {
			chunk = Bytes.alloc(CHUNK_SIZE);
		}
		if (++__inUse > __peak) {
			__peak = __inUse;
		}
		return chunk;
	}

	/** `chunk`, which `take` gave, back once its datagrams have gone. **/
	public function give(chunk:Bytes):Void {
		__inUse--;
		__idle.push(chunk);
		if (!__watched && __idle.length > SPARE && __registry != null) {
			__watched = true;
			__registry.watchQuiet(this);
		}
	}

	/**
		Asked by the registry every few seconds: lets go of the spare chunks
		left from the ask before, and makes spare what this interval did not
		need, all but `SPARE` once nothing was taken. Whether to go on asking.
	**/
	public function __releaseIfQuiet():Bool {
		// What went unused a whole interval before this one goes now.
		__spare.resize(0);
		var keep:Int = __taken ? __peak - __inUse : SPARE;
		if (keep < SPARE) {
			keep = SPARE;
		}
		// What this interval did not need waits one more as spare.
		while (__idle.length > keep) {
			__spare.push(__idle.pop());
		}
		__taken = false;
		__peak = __inUse;
		if (__idle.length <= SPARE && __spare.length == 0) {
			__watched = false;
			return false;
		}
		return true;
	}
}
#end
