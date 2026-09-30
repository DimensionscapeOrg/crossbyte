package crossbyte.net;

/**
	How a `TurnClient` reaches its relay. What the relay relays is UDP either
	way; this is only the leg between the client and the relay.

	A network that lets nothing out but TCP -- a corporate firewall, a hotel's
	captive portal -- blocks the UDP a relay is usually reached by, and the
	peers behind it are exactly the ones that need a relay most. RFC 8656
	section 3.1 lets them reach it over TCP, or TLS over TCP to look like any
	other HTTPS, and carry the same messages framed for a stream.
**/
enum abstract TurnTransport(String) to String {
	/** Datagrams: what a relay listens on by default, port 3478. **/
	var UDP = "udp";

	/** A TCP connection, usually to port 3478 too. **/
	var TCP = "tcp";

	/**
		TLS over TCP, usually to port 5349 or 443. `TurnClient` frames it as it
		does TCP; the connection is the caller's to make, since a plain
		`Socket` does not speak TLS on every target.
	**/
	var TLS = "tls";
}
