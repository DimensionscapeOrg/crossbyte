package crossbyte.net;

/**
	What one RFC 5780 question to a STUN server found: the address it saw,
	where it answered from, and the other address it can answer from.
	`StunClient.probe` asks it.
**/
typedef StunProbe = {
	/** Where the server saw the question come from: this socket's mapping toward it. **/
	mapped:ReflexiveAddress,

	/** Where the answer came from, which a CHANGE-REQUEST moves. **/
	from:ReflexiveAddress,

	/** The server's OTHER-ADDRESS, or null from one that has no second address. **/
	otherAddress:Null<ReflexiveAddress>,

	/** Where the server says it answered from (RESPONSE-ORIGIN), or null. **/
	responseOrigin:Null<ReflexiveAddress>
}
