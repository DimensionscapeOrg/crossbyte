package crossbyte.net._internal.reliable;

import crossbyte.io.ByteArray;

/**
	One frame that has gone out and not been acknowledged.

	It carries when it was sent and when it is next due, because both are
	needed and neither was kept before: the send time is the round trip
	measurement that sets the retransmission timeout, and the deadline is what
	the session's single retransmission clock compares against, in place of
	every frame having a repeating timer of its own.

	What it sends is `length` bytes of `payload` from `offset`: its own
	buffer, into which `send` copied the message, or the bytes of a
	`PreparedDatagram` that many sessions send from. A frame comes from a
	`FramePool` and goes back to it once acknowledged, its buffer with it.
**/
class OutstandingFrame {
	/** The sequence it was sent under; set as it goes out. **/
	public var sequence:Int = 0;

	/** Where its bytes are: its own `buffer`, or a prepared message's, which it only reads. **/
	public var payload:ByteArray;

	/** Where in `payload` its bytes start. **/
	public var offset:Int = 0;

	/** How many bytes it carries. **/
	public var length:Int = 0;

	public var sentAt:Float;

	public var deadline:Float;

	/** One on the first send; Karn's algorithm reads it before sampling. **/
	public var attempts:Int = 1;

	/**
		Whether more of the same message follows this frame. Kept with the
		frame because a retransmission has to say it again.
	**/
	public var more:Bool;

	/**
		Whether the peer has said it holds this frame, past a gap it is still
		waiting to fill. Such a frame is not sent again, and no longer counts
		against the congestion window.
	**/
	public var sacked:Bool = false;

	/**
		Whether this is the graceful FIN `close()` sends rather than a
		PACKET: the last frame of the sequence, with no payload, sent and sent
		again as the frames before it are, and so acknowledged in order.
	**/
	public var fin:Bool = false;

	/**
		Its own buffer, kept with it from one message to the next, of its
		pool's `sizeClass`; null for a frame with none, which sends a prepared
		message's bytes or a FIN.
	**/
	public var buffer:ByteArray = null;

	/** Which of its pool's lists it goes back to; -1 for one no pool made. **/
	public var sizeClass:Int = -1;

	/** The next idle frame in its pool's list. **/
	public var next:OutstandingFrame = null;

	public function new(payload:ByteArray, sentAt:Float, deadline:Float, more:Bool = false) {
		this.payload = payload;
		this.length = payload != null ? payload.length : 0;
		this.sentAt = sentAt;
		this.deadline = deadline;
		this.more = more;
	}
}
