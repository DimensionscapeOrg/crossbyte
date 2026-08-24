package crossbyte.net.ice;

/**
	Where one candidate pair has got to in the checking.

	RFC 8445 section 6.1.2.6. A pair moves forward only: nothing that has
	succeeded is retried, and nothing that has failed is revived, so the check
	list drains rather than churning.
**/
enum abstract IceCandidatePairState(Int) {
	/**
		Waiting on another pair before it is worth trying.

		ICE freezes pairs so that several media streams sharing a path do not
		each pay for discovering it. A single data transport has one stream and
		nothing to wait for, so pairs here start `WAITING` -- this exists
		because the state is part of the model, not because anything sets it
		yet.
	**/
	var FROZEN = 0;

	/** Ready to be checked, as soon as the pacing allows. **/
	var WAITING = 1;

	/** A request has gone out and no answer has come back yet. **/
	var IN_PROGRESS = 2;

	/** Answered, so this pair is a path that demonstrably works. **/
	var SUCCEEDED = 3;

	/** Gave up: the retransmissions ran out, or the peer refused it. **/
	var FAILED = 4;
}
