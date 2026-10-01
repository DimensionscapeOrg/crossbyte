package crossbyte.net;

/**
	One TURN relay, and the credentials it wants: an entry in the list
	`PeerConnection.gatherRelayedFrom` works through.

	```haxe
	connection.gatherRelayedFrom([
		{address: "turn-eu.example.com", username: "user", password: "secret"},
		{address: "turn-us.example.com", port: 3479, username: "user", password: "secret"}
	]);
	```
**/
typedef TurnServer = {
	/** The relay's address or name. **/
	address:String,

	/** Its port; 3478 when left out. **/
	?port:Int,

	username:String,
	password:String,

	/**
		How the relay is reached: UDP when left out, or TCP or TLS for a
		network that lets only TCP out. See `TurnTransport`.
	**/
	?transport:TurnTransport
	#if !(macro || (js && !nodejs)),
	/**
		For a relay reached over TLS whose certificate chains to an authority
		the system does not trust, a private relay's own. See
		`TurnClient.certAuthority`.
	**/
	?certAuthority:Certificate,

	/**
		For a relay reached over TLS: false to accept its certificate unchecked,
		for a test against a relay with a throwaway one, never otherwise, and
		`certAuthority` is better even then. Checked when left out. See
		`TurnClient.verifyCert`.
	**/
	?verifyCert:Bool
	#end
}
