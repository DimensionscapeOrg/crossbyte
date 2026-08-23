package crossbyte.net;

@:structInit
/**
	An address and port as somebody outside sees them.

	Distinct from `Endpoint`, which is a parsed transport URI and carries a
	protocol, a secure flag and a resource path -- none of which mean anything
	about where a socket appears from outside. This is the pair and nothing
	else.

	"Reflexive" is the ICE term for it: the address a peer learns by asking
	something beyond its own NAT, as opposed to the host address it can read
	locally. The two differ for any peer behind NAT, and the difference is the
	whole reason to ask -- a peer that advertises its host address advertises
	somewhere no other peer can reach.
**/
class ReflexiveAddress {
	/** The address as seen from outside, in dotted-quad form. */
	public var address:String;

	/** The port as seen from outside, which a NAT may have translated. */
	public var port:Int;

	/**
		Whether the port survived unchanged.

		Worth knowing before attempting a direct connection: a NAT that keeps
		the port has an endpoint-independent mapping and hole punching through
		it works, while one that translates per destination will not let a
		third party in on the mapping it made for somebody else. Compare
		against the local port that was asked about.
	**/
	public inline function preservesPort(localPort:Int):Bool {
		return port == localPort;
	}

	public function toString():String {
		return address + ":" + port;
	}
}
