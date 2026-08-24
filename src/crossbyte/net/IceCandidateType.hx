package crossbyte.net;

/**
	How a candidate address was come by.

	The four kinds ICE defines, and the values are the tokens SDP uses for them
	(RFC 8839), so a candidate can be written out or read back without a
	translation table in between. That matters even for a transport that never
	speaks SDP: a browser peer on the other end of the exchange does, and these
	are the words it will use.

	The order they are listed in is the order they are worth having, which is
	also what `IceCandidate.typePreference` reports.
**/
enum abstract IceCandidateType(String) from String to String {
	/**
		An address of this machine's own, on an interface it holds.

		The best kind when it works, because nothing is in the path: two peers
		on one subnet reach each other directly. `LocalAddress` produces these.
	**/
	var HOST = "host";

	/**
		The outside of a NAT, as reported by a STUN server.

		What a peer elsewhere on the internet must dial. `StunClient` and
		`ReliableDatagramServerSocket.discoverPublicAddress` produce these.
	**/
	var SERVER_REFLEXIVE = "srflx";

	/**
		The outside of a NAT, as observed by the peer rather than a server.

		Discovered during the connectivity checks themselves: a check can arrive
		from a mapping neither side knew about, because a NAT allocated it for
		this particular destination. Ranked above server-reflexive precisely
		because it was learned from the peer that is actually going to use it.
	**/
	var PEER_REFLEXIVE = "prflx";

	/**
		An address on a TURN server that forwards to this peer.

		Last, and deliberately so: it works when nothing else does, and it costs
		a round trip through a third party for every packet in both directions.
	**/
	var RELAYED = "relay";
}
