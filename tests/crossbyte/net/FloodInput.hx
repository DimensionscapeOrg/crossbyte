package crossbyte.net;

import haxe.io.Bytes;

/**
	A socket's input standing in for a peer that sends faster than it is
	read: every read is answered in full, up to `perCall` bytes, from
	`pattern` repeated end to end, until `available` bytes have gone; then
	it reports itself blocked, as a drained non-blocking socket does.

	A real peer is no use for this. Whether it stays ahead of the reader is
	a race, and over loopback in one process the reader often wins, while
	a client on another core, or another machine, keeps every read full for
	as long as it has something to send. `perCall` at 16 KB is a TLS socket,
	whose reads stop at the end of a record.
**/
class FloodInput extends haxe.io.Input {
	public var available:Int;
	public var taken(default, null):Int = 0;
	public final perCall:Int;

	// Cleared by sys.net.Socket.close() on the inputs it made itself.
	public var __s:Dynamic = null;

	private final __pattern:Bytes;

	public function new(pattern:Bytes, available:Int, perCall:Int) {
		__pattern = pattern;
		this.available = available;
		this.perCall = perCall;
	}

	override public function readByte():Int {
		if (available <= 0) {
			throw haxe.io.Error.Blocked;
		}
		var b:Int = __pattern.get(taken % __pattern.length);
		taken++;
		available--;
		return b;
	}

	override public function readBytes(buffer:Bytes, pos:Int, len:Int):Int {
		if (available <= 0) {
			throw haxe.io.Error.Blocked;
		}
		var n:Int = len < perCall ? len : perCall;
		if (n > available) {
			n = available;
		}
		var done:Int = 0;
		while (done < n) {
			var at:Int = (taken + done) % __pattern.length;
			var run:Int = __pattern.length - at;
			if (run > n - done) {
				run = n - done;
			}
			buffer.blit(pos + done, __pattern, at, run);
			done += run;
		}
		taken += n;
		available -= n;
		return n;
	}
}
