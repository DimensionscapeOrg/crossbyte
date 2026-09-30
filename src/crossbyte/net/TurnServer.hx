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
		How the relay is reached: UDP when left out, or TCP for a network that
		lets only TCP out. See `TurnTransport`.
	**/
	?transport:TurnTransport
}
