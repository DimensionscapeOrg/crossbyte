package crossbyte.net;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
	A socket's output standing in for a kernel buffer that fills: it takes at
	most `perCall` bytes a write, and `room` bytes in all until the test makes
	more, then reports itself blocked as a full non-blocking socket does. What
	it takes it keeps, in order, so what was sent can be checked.

	A real kernel is no use for this on Windows, which takes a whole write or
	none of it, so a partial write (the case being tested) never happens
	over loopback there. A TLS socket makes one every 16 KB record, which is
	what `perCall` imitates.
**/
class ThrottledOutput extends haxe.io.Output {
	public var taken(default, null):BytesBuffer = new BytesBuffer();
	public var room:Int;
	public final perCall:Int;

	// Cleared by sys.net.Socket.close() on the outputs it made itself.
	public var __s:Dynamic = null;

	public function new(perCall:Int, room:Int) {
		this.perCall = perCall;
		this.room = room;
	}

	override public function writeByte(c:Int):Void {
		if (room <= 0) {
			throw haxe.io.Error.Blocked;
		}
		taken.addByte(c);
		room--;
	}

	override public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		if (room <= 0) {
			throw haxe.io.Error.Blocked;
		}
		var n:Int = len < perCall ? len : perCall;
		if (n > room) {
			n = room;
		}
		taken.addBytes(s, pos, n);
		room -= n;
		return n;
	}
}
