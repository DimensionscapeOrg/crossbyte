package crossbyte.net.ice;

import crossbyte.errors.ArgumentError;
import crossbyte.net.ReflexiveAddress;

/**
	One address a peer might be reachable at, and how good it is thought to be.

	ICE does not pick an address; it collects every address a peer might work on
	and then finds out which ones do. This is one entry in that collection. A
	peer gathers its own -- `LocalAddress` for the host kind,
	`ReliableDatagramServerSocket.discoverPublicAddress` for the reflexive kind
	-- sends them to the other side by whatever means it already has, and
	receives the other side's in return.

	```haxe
	var mine = [
		IceCandidate.host(local, server.localPort),
		IceCandidate.serverReflexive(reflexive)
	];
	```

	## Priority is not a preference

	The number here is not an opinion that can be revised later. It goes over
	the wire, both peers compute pair priorities from it, and RFC 8445 requires
	both to arrive at the same ordering -- so a candidate's priority is fixed
	when it is created and travels with it. That is why `priority` can be given
	rather than only computed: a candidate that arrived from a peer carries the
	number that peer assigned, and recomputing it locally would be a way for the
	two sides to disagree about what to try first.

	## Not an SDP encoder

	This carries what a candidate is, not how to write one down. CrossByte's own
	mesh exchanges them over a transport it already has, and a peer talking to a
	browser needs SDP -- but which of those is wanted is the application's
	business, and `IceCandidateType` already holds the SDP tokens for whichever
	way it goes.
**/
class IceCandidate {
	/**
		The component a media stream's data travels on, and the only one a data
		transport has.

		RFC 8445 numbers the parts of a stream that need their own transport:
		RTP is 1 and RTCP is 2. A reliable datagram session is one flow with no
		control channel beside it, so it is always component 1 -- but the number
		is still in the priority formula, and a peer that does split a stream
		needs the field to mean what the RFC says it means.
	**/
	public static inline var COMPONENT_RTP:Int = 1;

	/** The second component of a media stream, where one exists. **/
	public static inline var COMPONENT_RTCP:Int = 2;

	/**
		The local preference for a host with one route to a peer.

		RFC 8445 uses this to order a multi-homed host's own interfaces against
		each other. `LocalAddress` answers with the single interface that
		reaches a given destination rather than enumerating them, so there is
		nothing here to break a tie between and the maximum is the honest value.
		A caller that does its own enumeration should pass its own.
	**/
	public static inline var DEFAULT_LOCAL_PREFERENCE:Int = 65535;

	private static inline var MAX_TYPE_PREFERENCE:Int = 126;
	private static inline var MAX_LOCAL_PREFERENCE:Int = 65535;

	/** How this address was come by, which is most of what decides its priority. **/
	public var type(default, null):IceCandidateType;

	/** The address a peer should dial. Numeric. **/
	public var address(default, null):String;

	/** The port a peer should dial. **/
	public var port(default, null):Int;

	/** Which part of a stream this carries; `COMPONENT_RTP` for a data transport. **/
	public var component(default, null):Int;

	/**
		What both peers order candidate pairs by.

		Computed from the type, the local preference and the component when this
		candidate is one of ours, and taken as given when it came from a peer.
	**/
	public var priority(default, null):Int;

	/**
		@param priority The peer's own number, for a candidate that arrived from
		one. Omitted for a candidate of this host's, which computes it.
		@throws ArgumentError if the address is empty, the port is outside the
		usable range, or the component is not a positive number the formula can
		hold.
	**/
	public function new(type:IceCandidateType, address:String, port:Int, component:Int = COMPONENT_RTP, ?priority:Null<Int>,
			localPreference:Int = DEFAULT_LOCAL_PREFERENCE) {
		if (address == null || address.length == 0) {
			throw new ArgumentError("A candidate needs an address.");
		}

		// Port 0 is the wildcard a socket binds with, not a port anything can
		// be dialled on -- and a candidate whose whole purpose is to be dialled
		// is worse than useless with one.
		if (port <= 0 || port > 65535) {
			throw new ArgumentError("A candidate needs a port a peer can dial, not " + port + ".");
		}

		if (component < 1 || component > 256) {
			throw new ArgumentError("A component id must be between 1 and 256, not " + component + ".");
		}

		this.type = type;
		this.address = address;
		this.port = port;
		this.component = component;
		this.priority = priority != null ? priority : computePriority(type, localPreference, component);
	}

	/**
		An address on an interface this machine holds.

		```haxe
		LocalAddress.forDestination(peer.address).then(function(local) {
			var candidate = IceCandidate.host(local, server.localPort);
		});
		```
	**/
	public static function host(address:String, port:Int, component:Int = COMPONENT_RTP,
			localPreference:Int = DEFAULT_LOCAL_PREFERENCE):IceCandidate {
		return new IceCandidate(HOST, address, port, component, null, localPreference);
	}

	/**
		The outside of a NAT, from what a STUN server reported.

		Takes the `ReflexiveAddress` the discovery calls hand back, since its
		port is the translated one and pairing it with any other would describe
		somewhere nobody can reach.
	**/
	public static function serverReflexive(reflexive:ReflexiveAddress, component:Int = COMPONENT_RTP,
			localPreference:Int = DEFAULT_LOCAL_PREFERENCE):IceCandidate {
		if (reflexive == null) {
			throw new ArgumentError("A reflexive candidate needs a discovered address.");
		}

		return new IceCandidate(SERVER_REFLEXIVE, reflexive.address, reflexive.port, component, null, localPreference);
	}

	/**
		The recommended type preference, RFC 8445 section 5.1.2.2.

		Recommended rather than required: the RFC fixes the formula and leaves
		these numbers to the implementation, asking only that host beats
		reflexive and that anything beats a relay. These are the values it
		suggests, and using them means a CrossByte peer and a browser order the
		same pairs the same way.
	**/
	public static function typePreference(type:IceCandidateType):Int {
		return switch (type) {
			case HOST: 126;
			case PEER_REFLEXIVE: 110;
			case SERVER_REFLEXIVE: 100;
			case RELAYED: 0;
			// An unrecognised type from a peer is not a reason to fail; it is a
			// reason to try it last, which is what a relay's preference means.
			case _: 0;
		}
	}

	/**
		RFC 8445 section 5.1.2.1:

		    priority = 2^24 * type preference
		             + 2^8  * local preference
		             + (256 - component id)

		The shape is deliberate. The type dominates, so a host candidate always
		outranks a reflexive one however the lower terms fall; the local
		preference breaks ties between one host's interfaces; and the component
		term is subtracted so that component 1 comes first, since a stream is
		useless without its data even if its control channel connects.

		The largest value this can produce is 2130706431, which is inside a
		signed 32-bit integer -- the RFC chose the exponents so it would be.
	**/
	public static function computePriority(type:IceCandidateType, localPreference:Int = DEFAULT_LOCAL_PREFERENCE,
			component:Int = COMPONENT_RTP):Int {
		var preference = typePreference(type);

		if (preference < 0 || preference > MAX_TYPE_PREFERENCE) {
			throw new ArgumentError("A type preference must be between 0 and 126, not " + preference + ".");
		}

		if (localPreference < 0 || localPreference > MAX_LOCAL_PREFERENCE) {
			throw new ArgumentError("A local preference must be between 0 and 65535, not " + localPreference + ".");
		}

		if (component < 1 || component > 256) {
			throw new ArgumentError("A component id must be between 1 and 256, not " + component + ".");
		}

		return (preference * 16777216) + (localPreference * 256) + (256 - component);
	}

	/**
		Whether this and `other` describe the same place.

		Address, port and component, and not the priority or the type: the same
		address discovered twice by different means is one place to try, and
		trying it twice would spend a check on nothing.
	**/
	public function sameAs(other:IceCandidate):Bool {
		if (other == null) {
			return false;
		}

		return address == other.address && port == other.port && component == other.component;
	}

	/**
		Whether a packet from this candidate could reach `other` at all.

		A candidate pair needs both halves in the same address family. An IPv4
		socket cannot send to an IPv6 address, so pairing them would spend a
		connectivity check to learn something already known.
	**/
	public function canReach(other:IceCandidate):Bool {
		if (other == null) {
			return false;
		}

		return component == other.component && isIPv6() == other.isIPv6();
	}

	/** Whether this address is IPv6, decided by the only thing that separates them. **/
	public inline function isIPv6():Bool {
		return address.indexOf(":") >= 0;
	}

	public function toString():String {
		return (this.type : String) + " " + address + ":" + port + " (priority " + priority + ", component " + component + ")";
	}
}
