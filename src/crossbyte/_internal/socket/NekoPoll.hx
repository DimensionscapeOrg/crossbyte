package crossbyte._internal.socket;

#if neko
import sys.net.Socket;

/**
	neko's poll natives, which its `sys.net.Socket` never exposed.

	`select` there takes at most 64 sockets on Windows, the default
	`FD_SETSIZE`: and throws past it, so a server's registry, which selected
	every socket it held at once, serviced none of them from the 65th
	connection on: 39 of 100 connections timed out. On POSIX an `fd_set`
	cannot hold a descriptor of 1024 or more at all. The poll natives have
	neither limit: on Windows they size their sets to what they are given,
	elsewhere they call `poll()`. The shape is hxcpp's `cpp.net.Poll`, which
	these natives are the originals of.

	On 64-bit Windows they size those sets wrongly, and this works around it.
	`FDSIZE(n)` there is `sizeof(u_int) + n * sizeof(SOCKET)`, but an `fd_set`'s
	array starts 8 bytes in, not 4, so each poll copies its set four bytes
	short: the upper half of the last socket is whatever that buffer held
	before, and when the collector has handed it out used, `select` refuses
	the set as holding something that is not a socket. Measured over recycled
	memory, 136 of 200 polls failed so. hxcpp's copy of these natives measures
	from `offsetof(fd_set, fd_array)` and is unaffected.

	So each buffer is primed once, before its first real poll, through a set
	one short of full, every byte a later, smaller set's copy leaves alone
	is then the zero upper half of a real socket, and two slots beyond what
	this reports as its capacity are kept for that: one the short copy never
	reaches, and one because a full set would overrun the short allocation.
	With natives that size their sets rightly the priming is merely unneeded.
**/
@:noCompletion
final class NekoPoll {
	private static var __alloc:Dynamic = neko.Lib.load("std", "socket_poll_alloc", 1);
	private static var __prepare:Dynamic = neko.Lib.load("std", "socket_poll_prepare", 3);
	private static var __events:Dynamic = neko.Lib.load("std", "socket_poll_events", 2);
	private static var __windows:Bool = Sys.systemName() == "Windows";

	/** Most sockets, read and write together, one `prepare` may name. **/
	public var capacity(default, null):Int;

	@:noCompletion private var __max:Int;
	@:noCompletion private var __handle:Dynamic;
	@:noCompletion private var __primed:Bool = false;
	@:noCompletion private var __readIndexes:neko.NativeArray<Int>;
	@:noCompletion private var __writeIndexes:neko.NativeArray<Int>;

	public function new(capacity:Int) {
		this.capacity = capacity;
		__max = capacity + 2;
		__handle = __alloc(__max);
		__primed = !__windows;
	}

	/**
		Names the sockets the next `events` watches, until the next call.
		Neither list may hold a closed socket.
	**/
	public function prepare(read:Array<Socket>, write:Null<Array<Socket>>):Void {
		if (!__primed) {
			var any:Null<Socket> = read.length > 0 ? read[0] : (write != null && write.length > 0 ? write[0] : null);
			if (any != null) {
				__prime(any);
			}
		}

		var indexes:neko.NativeArray<Dynamic> = __prepare(__handle, __handles(read), __handles(write));
		__readIndexes = indexes[0];
		__writeIndexes = indexes[1];
	}

	/** Waits up to `timeout` seconds for any of them to be ready. **/
	public inline function events(timeout:Float):Void {
		__events(__handle, timeout);
	}

	/**
		The position in `prepare`'s read list of the `n`th socket found
		readable, or -1 past the last.
	**/
	public inline function readIndex(n:Int):Int {
		return __readIndexes[n];
	}

	/** The same for the write list. **/
	public inline function writeIndex(n:Int):Int {
		return __writeIndexes[n];
	}

	/**
		Fills each output set's buffer with a real socket, through a poll of a
		set one short of full; see the class notes. The polls are for their
		copies: what they report, or refuse, is of no account.
	**/
	@:noCompletion private function __prime(socket:Socket):Void {
		__primed = true;
		var many:Array<Socket> = [for (_ in 0...__max - 1) socket];
		try {
			__prepare(__handle, __handles(many), __handles(null));
			__events(__handle, 0.0);
		} catch (_:Dynamic) {}
		try {
			__prepare(__handle, __handles(null), __handles(many));
			__events(__handle, 0.0);
		} catch (_:Dynamic) {}
	}

	private static function __handles(sockets:Null<Array<Socket>>):neko.NativeArray<Dynamic> {
		var count:Int = sockets == null ? 0 : sockets.length;
		var handles:neko.NativeArray<Dynamic> = neko.NativeArray.alloc(count);
		for (i in 0...count) {
			handles[i] = untyped sockets[i].__s;
		}
		return handles;
	}
}
#end
