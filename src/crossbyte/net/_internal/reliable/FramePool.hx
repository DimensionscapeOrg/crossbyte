package crossbyte.net._internal.reliable;

import crossbyte.io.ByteArray;
import haxe.ds.Vector;

/**
	The frames reliable sessions keep until the peer acknowledges them, and
	the buffers a message is copied into for them, kept for the next
	message once acknowledged rather than left to the collector.

	A reliable message is held until it is acknowledged, since the network
	may lose it and only this side can send it again, and the caller may
	reuse its own bytes the moment `send` returns; so `send` copies it. That
	copy was a `ByteArray`, its `Bytes` and its storage, and a frame to hold
	it: 424 bytes natively for a 200-byte message, garbage a round trip
	later, for every reliable message a server sent. It is now made into a
	frame from here, whose buffer is the smallest of 64, 128, 256, 512, 768
	or 1,024 bytes, or a whole frame's 1,200, that holds the message, and the
	frame comes
	back here when the peer acknowledges it: the memory is still held while
	the message is in flight, and nothing is allocated for it. A frame that
	sends a `PreparedDatagram`'s bytes, or a FIN, has no buffer, and comes
	from a list of its own.

	One pool serves every session of a server, all on the server's
	runtime, sending one message at a time, and a session with no server
	has one of its own.

	**How much it keeps.** As many frames, in use and idle together, as
	were in use at once lately, and `SPARE` more. A game server's tick sends
	to every session and has it all acknowledged before the next, so what is
	in use rises to a thousand and falls to none, every tick; a pool that
	kept only what was in use at each moment kept half, and the other half
	was made again every tick. "Lately" is this period of `PEAK_PERIOD`
	seconds and the one before it, so once the traffic falls the pool keeps
	less within two periods; and once nothing has come back to it for
	`QUIET_PERIOD` seconds, with nothing in use, it lets go of all but
	`SPARE` (`quiet`, from each session's keepalive check).

	**Threading.** None: its sessions' runtime's thread only.
**/
final class FramePool {
	/** Frames kept beyond the most in use lately. **/
	public static inline var SPARE:Int = 64;

	/** How long, in seconds, the most in use at once is remembered: this period and the one before. **/
	public static inline var PEAK_PERIOD:Float = 10.0;

	/** How long, in seconds, a pool with nothing in use waits before it lets all but `SPARE` go. **/
	public static inline var QUIET_PERIOD:Float = 10.0;

	/** The classes of a frame's own buffer; the frames with none come after. **/
	@:noCompletion private static inline var BUFFERED_CLASSES:Int = 7;

	@:noCompletion private static inline var BARE:Int = BUFFERED_CLASSES;

	// The head of each class's list of idle frames, linked through `next`.
	@:noCompletion private var __free:Vector<OutstandingFrame>;
	@:noCompletion private var __idle:Int = 0;
	@:noCompletion private var __inUse:Int = 0;

	// The most in use at once this period, and in the one before; when this
	// one began; and when a frame last came back.
	@:noCompletion private var __peak:Int = 0;
	@:noCompletion private var __lastPeak:Int = 0;
	@:noCompletion private var __periodFrom:Float = -1;
	@:noCompletion private var __lastGiven:Float = -1;

	/** Frames this pool has made, ever: what a steady flow should leave unchanged. **/
	public var made(default, null):Int = 0;

	public function new() {
		__free = new Vector(BUFFERED_CLASSES + 1);
		for (i in 0...BUFFERED_CLASSES + 1) {
			__free[i] = null;
		}
	}

	/** Frames taken and not given back. **/
	public var inUse(get, never):Int;

	/** Frames held here for the next message. **/
	public var idle(get, never):Int;

	@:noCompletion private inline function get_inUse():Int {
		return __inUse;
	}

	@:noCompletion private inline function get_idle():Int {
		return __idle;
	}

	/**
		The capacity of a class's buffer: 64 bytes doubling to 512, then 768
		and 1,024, a snapshot of a kilobyte is held in a kilobyte, not in
		the 1,200 of a whole frame, and a whole frame's payload last.
	**/
	public static inline function capacityOf(sizeClass:Int):Int {
		return sizeClass < 4 ? 64 << sizeClass : (sizeClass == 4 ? 768 : (sizeClass == 5 ? 1024 : ReliableDatagramProtocol.MAX_PAYLOAD_SIZE));
	}

	/** The smallest class whose buffer holds `length` bytes, at most a frame's payload. **/
	public static inline function classOf(length:Int):Int {
		return length <= 64 ? 0 : (length <= 128 ? 1 : (length <= 256 ? 2 : (length <= 512 ? 3 : (length <= 768 ? 4 : (length <= 1024 ? 5 : 6)))));
	}

	/**
		A frame whose own buffer holds `length` bytes, at most a frame's
		payload, for the caller to copy them into: `payload` is the buffer,
		from 0, for `length` bytes.
	**/
	public function take(length:Int):OutstandingFrame {
		var sizeClass:Int = classOf(length);
		var frame:Null<OutstandingFrame> = __pop(sizeClass);
		if (frame == null) {
			var buffer = new ByteArray(capacityOf(sizeClass));
			frame = new OutstandingFrame(buffer, 0, 0);
			frame.buffer = buffer;
			frame.sizeClass = sizeClass;
			made++;
		}
		frame.payload = frame.buffer;
		frame.offset = 0;
		frame.length = length;
		return frame;
	}

	/** A frame with no buffer of its own: for a prepared message's bytes, or a FIN. **/
	public function takeBare():OutstandingFrame {
		var frame:Null<OutstandingFrame> = __pop(BARE);
		if (frame == null) {
			frame = new OutstandingFrame(null, 0, 0);
			frame.sizeClass = BARE;
			made++;
		}
		return frame;
	}

	/**
		A frame its session has finished with, at `now` on the session's
		clock: acknowledged, or its session gone, and out of every list the
		session keeps. Kept for the next message while the pool holds fewer
		than were in use at once lately and `SPARE` more, and let go
		otherwise; one this pool did not make is let go.
	**/
	public function give(frame:OutstandingFrame, now:Float):Void {
		var sizeClass:Int = frame.sizeClass;
		if (sizeClass < 0) {
			return;
		}
		__inUse--;
		__lastGiven = now;
		if (__periodFrom < 0) {
			__periodFrom = now;
		} else if (now - __periodFrom >= PEAK_PERIOD) {
			__lastPeak = __peak;
			__peak = __inUse;
			__periodFrom = now;
		}
		// Nothing of the message is held on to: a prepared message's bytes
		// are let go, and the buffer's own are written over by the next.
		frame.payload = frame.buffer;
		frame.offset = 0;
		frame.length = 0;
		frame.attempts = 1;
		frame.more = false;
		frame.sacked = false;
		frame.fin = false;
		var keep:Int = (__peak > __lastPeak ? __peak : __lastPeak) + SPARE;
		if (__idle + __inUse >= keep) {
			// Not pooled again, whatever still refers to it.
			frame.sizeClass = -1;
			return;
		}
		frame.next = __free[sizeClass];
		__free[sizeClass] = frame;
		__idle++;
	}

	/**
		Lets all but `SPARE` idle frames go, if nothing is in use and nothing
		has come back for `QUIET_PERIOD` seconds before `now`: the traffic
		that needed them has stopped. Each session asks at its keepalive
		check; a busy pool says no at once.
	**/
	public function quiet(now:Float):Void {
		if (__inUse > 0 || __idle <= SPARE || (__lastGiven >= 0 && now - __lastGiven < QUIET_PERIOD)) {
			return;
		}
		// The largest buffers first, the frames with none last.
		var excess:Int = __idle - SPARE;
		var sizeClass:Int = BUFFERED_CLASSES - 1;
		while (excess > 0 && sizeClass >= 0) {
			excess = __drop(sizeClass, excess);
			sizeClass--;
		}
		__drop(BARE, excess);
		__peak = 0;
		__lastPeak = 0;
	}

	/** Lets up to `count` idle frames of a class go; says how many more are to go. **/
	@:noCompletion private function __drop(sizeClass:Int, count:Int):Int {
		while (count > 0) {
			var frame:Null<OutstandingFrame> = __free[sizeClass];
			if (frame == null) {
				break;
			}
			__free[sizeClass] = frame.next;
			frame.next = null;
			frame.sizeClass = -1;
			__idle--;
			count--;
		}
		return count;
	}

	@:noCompletion private inline function __pop(sizeClass:Int):Null<OutstandingFrame> {
		var frame:Null<OutstandingFrame> = __free[sizeClass];
		if (frame != null) {
			__free[sizeClass] = frame.next;
			frame.next = null;
			__idle--;
		}
		__inUse++;
		if (__inUse > __peak) {
			__peak = __inUse;
		}
		return frame;
	}
}
