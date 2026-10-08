package crossbyte.net;

/**
	How a NAT treats one socket's traffic, in RFC 4787's three terms: what
	`StunClient.classifyMapping` and `StunClient.classifyFiltering` find.

	The same three words describe two different things. *Mapping* is which
	public address and port the NAT gives this socket's traffic toward a
	destination: one for all of them, or a new one per destination address,
	or per address and port. *Filtering* is who may send back through a
	mapping once it exists: anyone, only a host this socket has sent to, or
	only the exact address and port it sent to.

	Together they say whether a peer can be reached directly. A peer learns
	where to send by asking a STUN server what it sees; a mapping that is not
	endpoint-independent gives the peer a different one, so the address it was
	told is not where its datagrams would arrive, and only a relay joins two
	such peers. Filtering decides whether a peer's first datagram gets in or
	has to wait for this side's to go out first, which ICE arranges.
**/
enum NatBehavior {
	/**
		Mapping: one public address and port for every destination.
		Filtering: anyone may send to it once it exists. Also what no NAT at
		all looks like.
	**/
	ENDPOINT_INDEPENDENT;

	/**
		Mapping: a new one per destination address, kept across its ports.
		Filtering: only a host this socket has sent to may send back, from any
		of its ports.
	**/
	ADDRESS_DEPENDENT;

	/**
		Mapping: a new one per destination address and port (the "symmetric
		NAT" of RFC 3489). Filtering: only the exact address and port this
		socket sent to may answer.
	**/
	ADDRESS_AND_PORT_DEPENDENT;
}
