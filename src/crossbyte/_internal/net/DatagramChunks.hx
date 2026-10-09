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
	five seconds), so a server broadcasting every frame takes nothing new;
	and once a whole interval has passed with none taken, all but one. A
	burst's chunks go five to ten seconds after it.

	One runtime's, used on its thread only.
**/
@:noCompletion
class DatagramChunks implements QuietRelease {
	/** A chunk's size: past the largest datagram, 65,507 bytes over IPv4 and 65,527 over IPv6. **/
	public static inline var CHUNK_SIZE:Int = 65536;

	/** Chunks kept however quiet the runtime: one, for a socket's next small pass. **/
	public static inline var SPARE:Int = 1;

	@:noCompletion private var __idle:Array<Bytes> = [];
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
		return __idle.length;
	}

	private inline function get_inUse():Int {
		return __inUse;
	}

	/** A chunk for a pass: one kept, or a new one. **/
	public function take():Bytes {
		__taken = true;
		var chunk:Null<Bytes> = __idle.pop();
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
		Asked by the registry every few seconds: keeps the chunks the busiest
		moment since the last time needed while chunks are still being taken,
		and all but `SPARE` once none was. Whether to go on asking.
	**/
	public function __releaseIfQuiet():Bool {
		var keep:Int = __taken ? __peak - __inUse : SPARE;
		if (keep < SPARE) {
			keep = SPARE;
		}
		if (__idle.length > keep) {
			__idle.resize(keep);
		}
		__taken = false;
		__peak = __inUse;
		if (__idle.length <= SPARE) {
			__watched = false;
			return false;
		}
		return true;
	}
}
#end
