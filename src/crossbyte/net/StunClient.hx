package crossbyte.net;

// Needs UDP, which a page has not got. A browser discovers its own reflexive
// address through RTCPeerConnection's ICE gathering instead.
#if !(js && !nodejs)
import crossbyte.Future;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunQuery;
import crossbyte._internal.net.IPv6;
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
#if !nodejs
import crossbyte._internal.net.Resolver;
import sys.net.Host;
#end

/**
	Asks a STUN server what address it sees this socket as.

	A peer behind NAT cannot answer that locally. `localAddress` is the private
	side of the mapping, and the address a peer must publish for others to dial
	is the public side -- which only something outside the NAT can report. That
	is the whole of what STUN does here, and it is the first thing any
	peer-to-peer transport needs: without it a peer can only advertise an
	address nobody else can reach.

	```haxe
	StunClient.discover("stun.l.google.com", 19302).then(function(address) {
		trace("the world sees " + address.address + ":" + address.port);
	}, function(error) {
		trace("could not find out: " + error);
	});
	```

	## Asking about a port you are already using

	Without a socket, each question binds one of its own and answers for a
	port nothing else holds. That is the general question.

	It is not the question a peer-to-peer application asks. A NAT keeps a
	mapping per socket, so what matters is how *the socket the application
	uses* appears -- and only a question sent from that socket can find out.
	Pass it:

	```haxe
	var socket = new DatagramSocket();
	socket.bind(0, "0.0.0.0");
	StunClient.discover("stun.example.org", 3478, 3000, socket).then(function(address) {
		trace("peers reach this socket at " + address);
	});
	```

	The socket is left open and as it was found. `ReliableDatagramServerSocket`
	and `PeerConnection` ask through their own sockets themselves.

	## What kind of NAT is in the way

	`classifyMapping` and `classifyFiltering` run RFC 5780's tests, through one
	socket, against a server that can answer from two addresses -- which most
	public STUN servers cannot, and say so by leaving out `OTHER-ADDRESS`.
	Asking two ordinary servers and comparing what they saw is only meaningful
	through one socket too: two sockets have two mappings, and comparing those
	calls every NAT symmetric.
**/
class StunClient {
	/**
		Whether this target can ask at all.

		Discovery needs a UDP socket, and it needs a cryptographically secure
		source for the transaction id -- both, not either. The id is what a
		reply is believed by, so it is the whole of what stops an off-path
		party who can guess it from handing this host an address of its
		choosing; drawn from a weak generator it would still look random and
		defend nothing. HashLink, python and lua have UDP and no CSPRNG, and
		this flag used to say `true` there while the first thing `discover`
		did threw -- a flag that lies leaves a caller no other path to take,
		which is the one thing a support flag exists to prevent.
	**/
	public static var isSupported(default, null):Bool = DatagramSocket.isSupported && crossbyte.crypto.SecureRandom.isSupported;

	/** The port STUN is registered on, and where public servers listen. */
	public static inline var DEFAULT_PORT:Int = 3478;

	/**
		Asks `server` for this host's reflexive address.

		The request is repeated on RFC 5389's schedule until the deadline, each
		gap twice the last -- see `StunQuery`, which owns the schedule and the
		reading of a reply for all three places here that ask this question.

		@param timeoutMs How long to keep asking before giving up. UDP has no
		failure to report -- a request that reaches nothing looks exactly like
		one still in flight -- so only a deadline ends a question nobody
		answers. 0 or less sets none, as it does for a connection's `timeout`:
		the question is asked until it is answered, or until the socket it is
		asked through closes -- so one asked through a socket of its own, with
		no deadline, holds that socket until the server answers. The same for
		every question here. 0 meant three seconds.
		@param socket The socket to ask through, whose mapping is then what the
		answer describes; bound, and not connected. It is left open, and left
		not receiving if it was not. The answer reaches its other `data`
		listeners too, as every datagram does -- a STUN message is the one
		whose first byte is below 4 (RFC 7983). Closing it ends the question,
		which fails. Without one, a socket of the question's own is bound and
		closed.
	**/
	public static function discover(server:String, port:Int = DEFAULT_PORT, timeoutMs:Int = 3000,
			?socket:DatagramSocket):Future<ReflexiveAddress> {
		var future = new Future<ReflexiveAddress>();

		__ask(server, port, timeoutMs, socket, null, function(answer:Null<StunAnswer>, failure:Null<String>, _:Bool):Void {
			if (answer != null) {
				@:privateAccess future.__resolve(answer.mapped);
			} else {
				@:privateAccess future.__fail(failure, failure == REQUIRED ? new ArgumentError("server") : null);
			}
		});

		return future;
	}

	/**
		Asks one RFC 5780 question: what `server` sees, and what it says about
		itself -- the other address it can answer from, and where it answered
		from. The building block `classifyMapping` and `classifyFiltering` are
		made of, for a caller running RFC 5780's other tests.

		@param timeoutMs As for `discover`: 0 or less is no deadline.
		@param socket As for `discover`. Every question about one mapping has
		to go through the socket that owns it.
		@param changeAddress Ask the server to answer from its other address.
		@param changePort Ask it to answer from its other port. A NAT that
		filters shows it by not letting that answer in, so such a question can
		time out on a network where nothing is wrong.
	**/
	public static function probe(server:String, port:Int = DEFAULT_PORT, timeoutMs:Int = 3000, ?socket:DatagramSocket,
			changeAddress:Bool = false, changePort:Bool = false):Future<StunProbe> {
		var future = new Future<StunProbe>();
		var attributes = (changeAddress || changePort) ? [StunMessage.changeRequest(changeAddress, changePort)] : null;

		__ask(server, port, timeoutMs, socket, attributes, function(answer:Null<StunAnswer>, failure:Null<String>, _:Bool):Void {
			if (answer != null) {
				@:privateAccess future.__resolve(__probeOf(answer));
			} else {
				@:privateAccess future.__fail(failure, failure == REQUIRED ? new ArgumentError("server") : null);
			}
		});

		return future;
	}

	/**
		How the NAT in front of `socket` maps it toward different destinations:
		RFC 5780 section 4.3.

		Three questions through one socket -- to the server, to its other
		address on the same port, and to its other address and port -- and a
		comparison of what each saw. `server` has to be able to answer from two
		addresses; one that cannot leaves `OTHER-ADDRESS` out and this fails
		saying so.

		@param timeoutMs For each question, as for `discover`: 0 or less is
		no deadline.
		@param socket As for `discover`. Without one, a socket of its own is
		used for all three and closed.
	**/
	public static function classifyMapping(server:String, port:Int = DEFAULT_PORT, timeoutMs:Int = 3000,
			?socket:DatagramSocket):Future<NatBehavior> {
		var future = new Future<NatBehavior>();
		var owned:Null<DatagramSocket> = null;

		function settle(behavior:Null<NatBehavior>, failure:Null<String>):Void {
			__closeOwned(owned);

			if (behavior != null) {
				@:privateAccess future.__resolve(behavior);
			} else {
				@:privateAccess future.__fail(failure, failure == REQUIRED ? new ArgumentError("server") : null);
			}
		}

		if (socket == null && __usable(server) == null) {
			owned = socket = __bindOwn();
			if (owned == null) {
				settle(null, "Could not bind a socket to ask through.");
				return future;
			}
		}

		__ask(server, port, timeoutMs, socket, null, function(first:Null<StunAnswer>, failure:Null<String>, _:Bool):Void {
			if (first == null) {
				settle(null, failure);
				return;
			}

			var other:Null<ReflexiveAddress> = __otherAddressOf(first, server, port);
			if (other == null) {
				settle(null, __noOtherAddress(first, server, port));
				return;
			}

			// Test II: the other address, the same port.
			__ask(other.address, port, timeoutMs, socket, null, function(second:Null<StunAnswer>, failure:Null<String>, _:Bool):Void {
				if (second == null) {
					settle(null, "RFC 5780's second question, to " + other.address + ":" + port + ", went unanswered: " + failure);
					return;
				}

				if (__same(first.mapped, second.mapped)) {
					settle(ENDPOINT_INDEPENDENT, null);
					return;
				}

				// Test III: the other address and the other port.
				__ask(other.address, other.port, timeoutMs, socket, null, function(third:Null<StunAnswer>, failure:Null<String>, _:Bool):Void {
					if (third == null) {
						settle(null, "RFC 5780's third question, to " + other + ", went unanswered: " + failure);
						return;
					}

					settle(__same(second.mapped, third.mapped) ? ADDRESS_DEPENDENT : ADDRESS_AND_PORT_DEPENDENT, null);
				});
			});
		});

		return future;
	}

	/**
		Who the NAT in front of `socket` lets send back through its mapping:
		RFC 5780 section 4.4.

		The server is asked to answer from its other address and port, then
		from its other port only. An answer that gets in says the NAT lets it;
		one that does not arrives as silence, so a filtering NAT is reported
		only once `timeoutMs` has passed for each question it stopped -- up to
		two deadlines on top of the first answer's time.

		@param timeoutMs For each question, as for `discover` -- but it has to
		be more than 0. Silence is the answer this listens for, and a question
		with no deadline would wait out a filtering NAT for good, so 0 or less
		fails at once, with an `ArgumentError` as its `cause`.
		@param socket As for `discover`. Without one, a socket of its own is
		used for all three and closed.
	**/
	public static function classifyFiltering(server:String, port:Int = DEFAULT_PORT, timeoutMs:Int = 3000,
			?socket:DatagramSocket):Future<NatBehavior> {
		var future = new Future<NatBehavior>();
		var owned:Null<DatagramSocket> = null;

		function settle(behavior:Null<NatBehavior>, failure:Null<String>):Void {
			__closeOwned(owned);

			if (behavior != null) {
				@:privateAccess future.__resolve(behavior);
			} else {
				@:privateAccess future.__fail(failure, failure == REQUIRED ? new ArgumentError("server") : null);
			}
		}

		if (timeoutMs <= 0) {
			@:privateAccess future.__fail("Classifying a NAT's filtering needs a deadline of more than 0 ms: a filtering NAT answers with "
				+ "silence, which only a deadline can hear.", new ArgumentError("timeoutMs"));
			return future;
		}

		if (socket == null && __usable(server) == null) {
			owned = socket = __bindOwn();
			if (owned == null) {
				settle(null, "Could not bind a socket to ask through.");
				return future;
			}
		}

		// Test I: an ordinary question, which makes the mapping the other two
		// ask about and learns where the server's other address is.
		__ask(server, port, timeoutMs, socket, null, function(first:Null<StunAnswer>, failure:Null<String>, _:Bool):Void {
			if (first == null) {
				settle(null, failure);
				return;
			}

			var other:Null<ReflexiveAddress> = __otherAddressOf(first, server, port);
			if (other == null) {
				settle(null, __noOtherAddress(first, server, port));
				return;
			}

			// Asked where it was asked before, so only the answer moves.
			var primary:String = first.from.address;

			// Test II: answered from the other address and port.
			__ask(primary, port, timeoutMs, socket, [StunMessage.changeRequest(true, true)],
				function(second:Null<StunAnswer>, failure:Null<String>, timedOut:Bool):Void {
					if (second != null) {
						var wrong = __answeredFromWrongPlace(second, other.address, other.port);
						settle(wrong == null ? ENDPOINT_INDEPENDENT : null, wrong);
						return;
					}

					if (!timedOut) {
						settle(null, failure);
						return;
					}

					// Test III: answered from the other port only.
					__ask(primary, port, timeoutMs, socket, [StunMessage.changeRequest(false, true)],
						function(third:Null<StunAnswer>, failure:Null<String>, timedOut:Bool):Void {
							if (third != null) {
								var wrong = __answeredFromWrongPlace(third, primary, other.port);
								settle(wrong == null ? ADDRESS_DEPENDENT : null, wrong);
								return;
							}

							settle(timedOut ? ADDRESS_AND_PORT_DEPENDENT : null, failure);
						});
				});
		});

		return future;
	}

	// ------------------------------------------------------------------

	/** The one failure that is the caller's mistake rather than the network's. **/
	@:noCompletion private static inline var REQUIRED:String = "A STUN server address is required.";

	/**
		Why nothing can be asked on this target or of this server, or null
		when something can.
	**/
	@:noCompletion private static function __usable(server:String):Null<String> {
		if (server == null || server == "") {
			return REQUIRED;
		}

		// Before anything is built: a caller that skipped the flag gets the
		// same failed future a checked caller would branch around, rather
		// than a throw from the first line that needed the CSPRNG.
		if (!isSupported) {
			return "STUN discovery is not available here: it needs a UDP socket and a cryptographically secure random source for "
				+ "the transaction id, and this target lacks at least one. Check StunClient.isSupported.";
		}

		return null;
	}

	/**
		Asks one question through `socket`, or through a socket of its own
		when that is null, and hands `then` the answer -- or why there is none,
		and whether that was the deadline passing. Always later, never inside
		this call, unless the question could not be asked at all.
	**/
	@:noCompletion private static function __ask(server:String, port:Int, timeoutMs:Int, socket:Null<DatagramSocket>,
			attributes:Null<Array<StunAttribute>>, then:(Null<StunAnswer>, Null<String>, Bool) -> Void):Void {
		var unusable:Null<String> = __usable(server);
		if (unusable != null) {
			then(null, unusable, false);
			return;
		}

		var owned:Bool = socket == null;

		if (!owned) {
			// A connected socket sends only to its peer, and an unbound one
			// has no port whose mapping could be asked about -- the answer
			// would describe whichever port a send happened to bind.
			if (socket.connected) {
				then(null, "Cannot ask " + server + ":" + port + " through a connected socket: it sends only to its peer.", false);
				return;
			}

			if (!socket.bound) {
				then(null, "Cannot ask " + server + ":" + port + " through a socket that is not bound: bind it first, since its port "
					+ "is the one whose mapping is asked about.", false);
				return;
			}
		}

		var query = new StunQuery(haxe.Timer.stamp(), timeoutMs, attributes);
		var runtime:CrossByte = CrossByte.current();
		var wasReceiving:Bool = !owned && socket.receiving;
		var settled:Bool = false;
		// Where the question goes: `server`, or for a name the address it
		// resolves to, null until then. A name given to the socket would be
		// looked up by it, and a name that did not resolve reported as the
		// socket's ioError -- which on a caller's socket is the caller's, and
		// says nothing to this question, so it waited out its deadline.
		var target:Null<String> = IPv6.isNumericAddress(server) ? server : null;
		var onData:DatagramSocketDataEvent->Void = null;
		var onError:IOErrorEvent->Void = null;
		var onClose:Event->Void = null;
		var onTick:TickEvent->Void = null;

		function finish(answer:Null<StunAnswer>, failure:Null<String>, timedOut:Bool):Void {
			if (settled) {
				return;
			}

			settled = true;
			runtime.removeEventListener(TickEvent.TICK, onTick);

			if (owned) {
				__closeOwned(socket);
			} else {
				socket.removeEventListener(DatagramSocketDataEvent.DATA, onData);
				socket.removeEventListener(IOErrorEvent.IO_ERROR, onError);
				socket.removeEventListener(Event.CLOSE, onClose);

				if (!wasReceiving) {
					try {
						socket.stopReceiving();
					} catch (_:Dynamic) {}
				}
			}

			then(answer, failure, timedOut);
		}

		function ask():Void {
			var payload:ByteArray = query.request.encode();
			socket.send(payload, 0, payload.length, target, port);
		}

		function askOrFail():Void {
			try {
				ask();
			} catch (e:Dynamic) {
				finish(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e), false);
			}
		}

		onData = function(event:DatagramSocketDataEvent):Void {
			if (settled) {
				return;
			}

			// Anything at all can arrive on a bound UDP port, so a datagram
			// that is not an answer to this question leaves it waiting rather
			// than failing it.
			switch (query.interpret(event.data)) {
				case NOT_OURS:
				case ANSWERED(address):
					finish({
						message: query.answer,
						mapped: address,
						from: ({address: IPv6.compress(event.srcAddress), port: event.srcPort} : ReflexiveAddress)
					}, null, false);
				case REFUSED(reason):
					finish(null, "The STUN server refused the request" + (reason != null ? ": " + reason : "."), false);
				case ANSWERED_WITHOUT_ADDRESS:
					finish(null, "The STUN server replied without a mapped address, so this host's public address is still unknown.", false);
				case UNUSABLE(reason):
					finish(null, "The STUN server's answer could not be used: " + reason + ".", false);
			}
		};

		// On a socket of its own, a send that cannot happen ends the question
		// now rather than at the deadline, which could only be reached by
		// waiting for nothing. A caller's socket reports its own traffic's
		// failures as well, which are nothing to do with this question.
		onError = function(event:IOErrorEvent):Void {
			finish(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + event.text, false);
		};

		// A caller's socket closed under the question ends it now. It ended
		// at the next ask, whose send failed -- with no deadline, gaps that
		// double put that hours away.
		onClose = function(_:Event):Void {
			finish(null, "The socket asking " + server + ":" + port + " for a reflexive address closed before an answer came.", false);
		};

		onTick = function(_:TickEvent):Void {
			if (settled) {
				return;
			}

			var now:Float = haxe.Timer.stamp();

			if (query.expired(now)) {
				// Damaged answers are not silence: the server answered, and a
				// filtering test must not read what reached it as filtered.
				// Only a question with a deadline gets here.
				var damage:Null<String> = query.damage();
				if (damage != null) {
					finish(null, "No usable reply from the STUN server at " + server + ":" + port + " within " + query.timeoutMs + "ms: " + damage
						+ ".", false);
				} else {
					finish(null, "No reply from the STUN server at " + server + ":" + port + " within " + query.timeoutMs
						+ "ms. UDP reports nothing when it is dropped, so a silent network and a wrong address look the same from here.",
						true);
				}
				return;
			}

			// Nothing to ask again before the name is looked up.
			if (target != null && query.shouldRetransmit(now)) {
				askOrFail();
			}
		};

		try {
			if (owned) {
				socket = new DatagramSocket();
				socket.bind(0, "0.0.0.0");
				socket.addEventListener(IOErrorEvent.IO_ERROR, onError);
			} else {
				socket.addEventListener(Event.CLOSE, onClose);
			}

			socket.addEventListener(DatagramSocketDataEvent.DATA, onData);
			socket.receive();
			runtime.addEventListener(TickEvent.TICK, onTick);
		} catch (e:Dynamic) {
			finish(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e), false);
			return;
		}

		if (target != null) {
			askOrFail();
			return;
		}

		__lookUp(server, socket, function(address:Null<String>, failure:Null<String>):Void {
			if (settled) {
				return;
			}

			if (address == null) {
				finish(null, "Could not ask " + server + ":" + port + " for a reflexive address: the name did not resolve (" + failure + ")",
					false);
				return;
			}

			target = address;
			askOrFail();
		});
	}

	/**
		Looks `name` up for `socket`, off the runtime's thread, and answers on
		it: natively through `Resolver`, and on Node through Node's resolver
		for the socket's address family, as its own sends would.
	**/
	@:noCompletion private static function __lookUp(name:String, socket:DatagramSocket, then:(Null<String>, Null<String>) -> Void):Void {
		#if nodejs
		var family:Int = @:privateAccess socket.__family == "udp6" ? 6 : 4;
		js.node.Dns.lookup(name, family, function(error:js.node.Dns.DnsError, address:String, _:js.node.Dns.DnsAddressFamily):Void {
			if (error != null || address == null) {
				then(null, error != null ? Std.string(error.message) : "no address");
			} else {
				then(IPv6.compress(address), null);
			}
		});
		#else
		Resolver.resolve(name, function(host:Null<Host>, failure:Null<String>):Void {
			then(host != null ? host.toString() : null, failure);
		});
		#end
	}

	/** A socket for questions that have to share one, or null if none would bind. **/
	@:noCompletion private static function __bindOwn():Null<DatagramSocket> {
		try {
			var socket = new DatagramSocket();
			socket.bind(0, "0.0.0.0");
			return socket;
		} catch (_:Dynamic) {
			return null;
		}
	}

	@:noCompletion private static function __closeOwned(socket:Null<DatagramSocket>):Void {
		if (socket != null) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}
	}

	@:noCompletion private static function __probeOf(answer:StunAnswer):StunProbe {
		return {
			mapped: answer.mapped,
			from: answer.from,
			otherAddress: answer.message.otherAddress(),
			responseOrigin: answer.message.responseOrigin()
		};
	}

	/**
		The server's other address, or null where it has none worth asking:
		RFC 5780's tests need a second address, not the first one named twice.
	**/
	@:noCompletion private static function __otherAddressOf(answer:StunAnswer, server:String, port:Int):Null<ReflexiveAddress> {
		var other:Null<ReflexiveAddress> = answer.message.otherAddress();

		if (other == null || other.address == answer.from.address || other.port == port) {
			return null;
		}

		return other;
	}

	@:noCompletion private static function __noOtherAddress(answer:StunAnswer, server:String, port:Int):String {
		var other:Null<ReflexiveAddress> = answer.message.otherAddress();

		if (other == null) {
			return "The STUN server at " + server + ":" + port + " gave no OTHER-ADDRESS, so it cannot answer from a second address "
				+ "and RFC 5780's tests cannot be run against it. Most public servers cannot; ask one that implements RFC 5780.";
		}

		return "The STUN server at " + server + ":" + port + " gave " + other + " as its other address, which does not differ from "
			+ answer.from + " in both address and port, so RFC 5780's tests cannot tell anything apart through it.";
	}

	/**
		Why an answer to a CHANGE-REQUEST cannot be believed, or null when it
		can. A server that ignored the request answers from where it was asked,
		and taking that answer would report the NAT as letting in what it was
		never shown.
	**/
	@:noCompletion private static function __answeredFromWrongPlace(answer:StunAnswer, address:String, port:Int):Null<String> {
		if (answer.from.address == address && answer.from.port == port) {
			return null;
		}

		return "The STUN server was asked to answer from " + address + ":" + port + " and answered from " + answer.from
			+ ", so it does not honour CHANGE-REQUEST and cannot show what this NAT filters.";
	}

	@:noCompletion private static inline function __same(a:ReflexiveAddress, b:ReflexiveAddress):Bool {
		return a.address == b.address && a.port == b.port;
	}
}

/** An answer, and what `probe` and the classifications read from it. **/
private typedef StunAnswer = {
	message:StunMessage,
	mapped:ReflexiveAddress,
	from:ReflexiveAddress
}
#end
