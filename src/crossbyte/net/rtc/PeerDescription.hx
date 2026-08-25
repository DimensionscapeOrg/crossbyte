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
}

/**
	Everything one peer must tell the other before they can connect.

	This is what an application carries over whatever channel already joins the
	two peers -- a WebSocket to a lobby server, an HTTP exchange, a copied and
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
}
