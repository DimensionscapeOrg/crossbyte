package crossbyte.net._internal.reliable;

import crossbyte.io.ByteArray;

/**
	One frame that has gone out and not been acknowledged.

	It carries when it was sent and when it is next due, because both are
	needed and neither was kept before: the send time is the round trip
	measurement that sets the retransmission timeout, and the deadline is what
	the session's single retransmission clock compares against, in place of
	every frame having a repeating timer of its own.
**/
class OutstandingFrame {
	public var payload:ByteArray;

	public var sentAt:Float;

	public var deadline:Float;

	/** One on the first send; Karn's algorithm reads it before sampling. **/
	public var attempts:Int = 1;

	/**
		Whether more of the same message follows this frame. Kept with the
		frame because a retransmission has to say it again.
	**/
	public var more:Bool;

	public function new(payload:ByteArray, sentAt:Float, deadline:Float, more:Bool = false) {
		this.payload = payload;
		this.sentAt = sentAt;
		this.deadline = deadline;
		this.more = more;
	}
}
