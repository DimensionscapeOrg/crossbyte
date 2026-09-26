package crossbyte.net.rtc;

/**
	One candidate, as it travels over signalling.

	The priority goes with it because both peers must sort the same pairs the
	same way, and a receiver that recomputed it locally would be free to
	disagree. The type is the SDP token, so a description can later be written
	as SDP without a translation table.
**/
typedef CandidateDescription = {
	var address:String;
	var port:Int;
	var type:String;
	var priority:Int;

	/**
		For a reflexive or relayed candidate, the address it was found from,
		SDP's `raddr`. Carried for the peer's diagnostics; nothing here pairs
		by it.
	**/
	@:optional var relatedAddress:String;

	/** SDP's `rport`, beside `relatedAddress`. **/
	@:optional var relatedPort:Int;
}

/**
	Everything one peer must tell the other before they can connect.

	This is what an application carries over whatever channel already joins the
	two peers, a WebSocket to a lobby server, an HTTP exchange, a copied and
	pasted string. CrossByte does not carry it, deliberately: signalling is the
	one part of WebRTC that is the application's own, and every application
	already has a channel it would rather use.

	It is a typedef rather than a string because CrossByte-to-CrossByte peers
	have no reason to serialise it any particular way. A browser on the other
	end needs SDP; that is a rendering of this, not a replacement for it, and it
	belongs in a codec rather than in the connection.
**/
typedef PeerDescription = {
	/** Names the ICE session. Not a secret. **/
	var usernameFragment:String;

	/** Signs the connectivity checks. Carried over signalling, never over the path being checked. **/
	var password:String;

	/** What the peer's DTLS certificate must hash to. The whole of the authentication. **/
	var fingerprint:String;

	/** Everywhere the peer might be reachable. **/
	var candidates:Array<CandidateDescription>;

	/**
		Which side of the DTLS handshake this peer will take, in SDP's words.

		`active` is the client, `passive` the server, and `actpass` says the
		peer will take whichever the answer leaves it. Optional here because two
		CrossByte peers settle it from the ICE role instead, it matters when
		the peer on the other end is a browser, which states it in the offer and
		expects the answer to choose.
	**/
	@:optional var setup:String;

	/**
		The largest message the peer will take, in bytes, or 0 for any size.

		SDP's `a=max-message-size`, RFC 8841, and a sender must not exceed it.
		Read from SDP, a document that leaves it out means the RFC's default of
		64 KB. A description passed as a structure without it is a CrossByte
		peer, and is taken to accept what this stack does,
		`SctpDataTransfer.MAX_REASSEMBLY`.
	**/
	@:optional var maxMessageSize:Int;

	/**
		The media section's id, SDP's `a=mid`. An answer repeats the offer's,
		which is how a browser matches the one to the other. `"0"` when absent.
	**/
	@:optional var mid:String;

	/**
		Whether the peer has finished gathering: no more candidates will be
		trickled. SDP's `a=end-of-candidates`, written only when this is true.
	**/
	@:optional var endOfCandidates:Bool;
}
