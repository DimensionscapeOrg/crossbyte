package crossbyte.net.rtc._internal.sctp;

/**
	Where an association has got to, RFC 4960 section 4.

	Named for what each state is waiting on rather than for how far along it is,
	because the two sides pass through different ones: the peer that asks waits
	for a cookie and then for it to be acknowledged, while the peer that is
	asked holds no state at all until a cookie comes back to it.
**/
enum abstract SctpAssociationState(Int) {
	/** Nothing has been asked for, and nothing is being held. **/
	var CLOSED = 0;

	/**
		Ready to be asked, holding no per-association state.

		Not one of RFC 4960's named states, because the RFC describes an
		endpoint rather than an object. It is the difference between a peer that
		will answer an INIT and one that will ignore it.
	**/
	var LISTENING = 1;

	/** An INIT has gone out and the INIT ACK has not come back. **/
	var COOKIE_WAIT = 2;

	/** The cookie has been echoed and not yet acknowledged. **/
	var COOKIE_ECHOED = 3;

	/** Open, and carrying data. **/
	var ESTABLISHED = 4;
}
