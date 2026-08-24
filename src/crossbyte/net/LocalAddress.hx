package crossbyte.net;

// Needs a UDP socket, which a page has not got -- so this follows
// `DatagramSocket` and `StunClient`, which are absent on the browser rather
// than present and refusing. A page has no routing table to ask in any case: it
// learns its host addresses from RTCPeerConnection, and since 2019 gets them
// behind random `.local` mDNS names unless the user has granted camera or
// microphone access, precisely because they are the fingerprint this class
// takes care not to hand out.
#if !(js && !nodejs)
import crossbyte.Future;
import crossbyte.errors.ArgumentError;
import crossbyte._internal.net.IPv6;
#if nodejs
import js.node.Dgram;
#elseif (sys && !eval && !neko)
import sys.net.Host;
import sys.net.UdpSocket;
#end

/**
	Which of this machine's addresses would reach a given peer.

	A socket bound to `0.0.0.0` answers `localAddress` with `0.0.0.0`, which is
	true and useless: it is every interface, so it names none. A peer needs one
	address it can dial. This is how to find out which.

	## Why not just resolve the hostname

	Because it is wrong on any machine with a virtual adapter, which is most of
	them. On the machine this was written on, `Host.localhost()` resolves to
	`172.28.192.1` -- the WSL adapter. Nothing on the LAN can reach it. The real
	address is `10.0.0.2`, and hostname resolution never mentions it.

	## Why not enumerate the interfaces

	That is what a full ICE agent does, and it is the right answer when you can
	afford the consequences. The same machine enumerates nine IPv4 addresses:
	Tailscale, two VMware adapters, four Hyper-V and WSL adapters, loopback, and
	one real one. Offering all nine means a peer spends its connectivity checks
	on eight addresses that cannot work, and it means handing that peer a map of
	every virtual network on the machine -- which browsers went to the trouble of
	mDNS names to stop leaking.

	## What this does instead

	Asks the routing table, by connecting a throwaway UDP socket toward the
	destination and reading back the source address the kernel chose. Connecting
	a UDP socket transmits nothing; it sets a default destination, and choosing
	one is what makes the kernel commit to an interface. So this is a local
	lookup that sends no packet and tells the destination nothing -- the address
	passed in need not be reachable, or even exist.

	```haxe
	// The address to advertise for reaching this particular peer.
	LocalAddress.forDestination(peer.address).then(function(host) {
		trace("they should dial me at " + host + ":" + server.localPort);
	});
	```

	## What it does not do

	It returns one address: the one that destination would be reached on. A
	genuinely multi-homed host that wants every path tried needs all of them, and
	that needs interface enumeration this has not got. The single answer is the
	right one for the case that actually bites -- two peers on one LAN, whose
	reflexive addresses many NATs will not hairpin back to them.
**/
class LocalAddress {
	/**
		Whether this target can ask at all.

		Reported rather than assumed, the same way `DatagramSocket` and
		`StunClient` report it, so a caller can branch instead of finding out
		from a failed future.
	**/
	public static var isSupported(default, null):Bool = DatagramSocket.isSupported;

	/**
		The address used as a stand-in for "somewhere out on the internet".

		RFC 5737 reserves this block for documentation, so it belongs to nobody
		and routes nowhere. That is exactly what is wanted: the question is which
		interface carries the default route, and naming a real host to ask it
		would implicate a third party in a lookup that never leaves the machine.
	**/
	private static inline var ROUTE_REFERENCE:String = "192.0.2.1";

	/** Reserved for documentation too, and the v6 half of the same question. **/
	private static inline var ROUTE_REFERENCE_V6:String = "2001:db8::1";

	/**
		The discard port, RFC 863. Nothing is sent to it, and connecting a UDP
		socket does not care whether anything listens -- but a port is required
		to name a destination, and this is the one that means nothing.
	**/
	private static inline var DISCARD_PORT:Int = 9;

	/**
		The address a peer at `destination` would see this machine as.

		@param destination A numeric address. Names are refused rather than
		resolved: resolving one blocks on sys targets and needs a callback on
		Node, so accepting them would make this call quietly expensive on one
		target and a different shape on another. Every caller that has a peer to
		reach already has its numeric address.
		@returns The local address, which is never the wildcard. Fails if this
		target has no UDP, if `destination` is not numeric, or if no interface
		claims a route to it.
	**/
	public static function forDestination(destination:String):Future<String> {
		var future = new Future<String>();

		if (destination == null || destination.length == 0) {
			@:privateAccess future.__fail("A destination address is required.", new ArgumentError("destination"));
			return future;
		}

		if (!IPv6.isNumericAddress(destination)) {
			@:privateAccess future.__fail("LocalAddress needs a numeric address, not a name: resolving one blocks on sys targets and is asynchronous on Node. Resolve it first.",
				new ArgumentError("destination"));
			return future;
		}

		__route(destination, future);
		return future;
	}

	/**
		The address this machine would be reached on from outside the LAN.

		The same question as `forDestination`, asked about the default route.
		This is the address to advertise when there is no particular peer in mind
		yet -- and the private half of what `StunClient` reports the public half
		of, which is how a peer can tell whether it is behind a NAT at all: if
		the two agree, it is not.

		@param preferIPv6 Ask which interface carries the default IPv6 route
		instead of the IPv4 one.
	**/
	public static function primary(preferIPv6:Bool = false):Future<String> {
		return forDestination(preferIPv6 ? ROUTE_REFERENCE_V6 : ROUTE_REFERENCE);
	}

	@:noCompletion private static function __route(destination:String, future:Future<String>):Void {
		var v6:Bool = destination.indexOf(":") >= 0;
		var wildcard:String = v6 ? "::" : "0.0.0.0";

		#if nodejs
		var socket = Dgram.createSocket({type: v6 ? "udp6" : "udp4"});
		var settled:Bool = false;

		var finish = function(address:Null<String>, error:Null<String>):Void {
			if (settled) {
				return;
			}
			settled = true;

			try {
				socket.close();
			} catch (_:Dynamic) {}

			if (address != null) {
				@:privateAccess future.__resolve(address);
			} else {
				@:privateAccess future.__fail(error, null);
			}
		};

		socket.on("error", function(e:Dynamic):Void {
			finish(null, "No interface claims a route to " + destination + ": " + Std.string(e));
		});

		try {
			socket.bind(0, wildcard, function():Void {
				try {
					// Node has had this since v12 and it does what the sys
					// targets do -- but `DatagramSocket` emulates connect()
					// rather than calling it, because the extern predates it, so
					// going through that class would read back the wildcard.
					// Reached directly here instead.
					untyped socket.connect(DISCARD_PORT, destination, function():Void {
						var chosen:String = null;
						try {
							chosen = socket.address().address;
						} catch (e:Dynamic) {
							finish(null, "The socket would not say which address it chose: " + Std.string(e));
							return;
						}
						__settle(chosen, wildcard, destination, finish);
					});
				} catch (e:Dynamic) {
					finish(null, "No interface claims a route to " + destination + ": " + Std.string(e));
				}
			});
		} catch (e:Dynamic) {
			finish(null, "A socket to ask with could not be opened: " + Std.string(e));
		}
		#elseif (sys && !eval && !neko)
		var socket:UdpSocket = null;
		var chosen:String = null;
		var failure:String = null;

		try {
			// Constructed inside the try, not before it. A function that hands
			// back a future has promised to report failure through it, and a
			// constructor that throws would break that promise on the one call
			// shape a caller cannot defend against.
			socket = new UdpSocket();
			socket.bind(new Host(wildcard), 0);
			socket.connect(new Host(destination), DISCARD_PORT);
			chosen = socket.host().host.toString();
		} catch (e:Dynamic) {
			failure = "No interface claims a route to " + destination + ": " + Std.string(e);
		}

		if (socket != null) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}

		if (failure != null) {
			@:privateAccess future.__fail(failure, null);
			return;
		}

		__settle(chosen, wildcard, destination, function(address:Null<String>, error:Null<String>):Void {
			if (address != null) {
				@:privateAccess future.__resolve(address);
			} else {
				@:privateAccess future.__fail(error, null);
			}
		});
		#else
		@:privateAccess future.__fail("This target has no UDP socket to ask the routing table with. Check LocalAddress.isSupported first.", null);
		#end
	}

	/**
		Rejects the wildcard.

		A socket that reports `0.0.0.0` after being pointed at a destination has
		not committed to an interface, which means the answer would be the same
		useless one the caller already had. Better to say so than to hand back an
		address that cannot be dialled.
	**/
	@:noCompletion private static function __settle(chosen:Null<String>, wildcard:String, destination:String, finish:Null<String>->Null<String>->Void):Void {
		if (chosen == null || chosen.length == 0 || chosen == wildcard) {
			finish(null, "The routing table gave no address for " + destination + ", only the wildcard. This machine may have no route to it.");
			return;
		}

		finish(IPv6.compress(chosen), null);
	}
}
#end
