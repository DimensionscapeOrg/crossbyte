package crossbyte.net;

@:structInit
/**
	An address and port as somebody outside sees them.

	Distinct from `Endpoint`, which is a parsed transport URI and carries a
	protocol, a secure flag and a resource path, none of which mean anything
	about where a socket appears from outside. This is the pair and nothing
	else.

	"Reflexive" is the ICE term for it: the address a peer learns by asking
	something beyond its own NAT, as opposed to the host address it can read
	locally. The two differ for any peer behind NAT, and the difference is the
	whole reason to ask: a peer that advertises its host address advertises
	somewhere no other peer can reach.
**/
class ReflexiveAddress {
	/**
		The address as seen from outside: dotted quad for IPv4, RFC 5952's
		compressed form for IPv6.
	**/
	public var address:String;

	/** The port as seen from outside, which a NAT may have translated. */
	public var port:Int;

	/**
		Whether the port survived unchanged, compared against the local port
		that was asked about.

		That is all it says. It is not the NAT's mapping behaviour, which is
		what decides whether a peer can reach this address, and it does not
		predict it either way: a NAT can keep the port toward the first
		destination and give the next one another, and one that renumbers
		every port can still keep a single mapping for every destination, as
		carrier-grade NATs commonly do. `StunClient.classifyMapping` finds the
		behaviour itself.
	**/
	public inline function preservesPort(localPort:Int):Bool {
		return port == localPort;
	}

	/**
		`address:port`, with an IPv6 address in brackets: RFC 5952 section
		6's form, since `2001:db8::7:3478` is itself a valid IPv6 address and
		says nothing about which part is the port.
	**/
	public function toString():String {
		return (address != null && address.indexOf(":") >= 0 ? "[" + address + "]" : address) + ":" + port;
	}
}
