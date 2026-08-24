package crossbyte.net.ice;

import crossbyte.Future;
import crossbyte.crypto.SecureRandom;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net.ReflexiveAddress;
import haxe.Int64;

/**
	Finds the path between two peers, by trying all of them at once.

	This is the part of ICE that actually connects. Candidates are gathered and
	exchanged elsewhere; what happens here is that every pair of them is checked
	with a signed STUN request, the ones that answer are kept, and the best of
	those is nominated. The peer at the other end is doing the same thing, and
	the two arrive at the same pair because they sort the list identically.

	## It has no socket

	The agent says what to send and where, through `onSend`, and is told what
	arrived, through `receive`. Time comes in through `poll`. Nothing here opens
	anything.

	That is not indirection for its own sake. Hole punching requires checks to
	leave from the very port a peer listens on -- one socket serving both -- so
	an agent that owned a socket of its own would be the wrong shape for the
	only case that matters. It also means two agents can be pointed at each
	other in a test with no network involved, on any target, and that the same
	agent can later sit on a reliable datagram socket, a plain one, or something
	that has not been written yet.

	```haxe
	var agent = new IceAgent(true, IceCredentials.generate());
	agent.onSend = (payload, address, port) -> server.sendTo(payload, address, port);
	agent.addLocalCandidate(IceCandidate.host(local, server.localPort));
	agent.start(theirCredentials, haxe.Timer.stamp());

	agent.connected.then(function(pair) {
		trace("use " + pair.remote.address + ":" + pair.remote.port);
	});
	```

	## Why both peers must check

	A NAT lets a datagram in only after one has gone out to that destination, so
	the first check in each direction is what opens the mapping for the other.
	Neither side can wait for the other to go first. A check arriving before its
	pair has been tried therefore causes that pair to be tried at once -- a
	triggered check -- which is what turns two peers punching blindly into a
	connection.
**/
class IceAgent {
	/**
		How long between two checks going out, in seconds.

		RFC 8445 calls this Ta and sets 50ms as the default. It exists because
		checks are sent to addresses that may be unreachable, and a burst of
		them to a NAT that is dropping everything looks exactly like a flood.
	**/
	public static inline var PACING:Float = 0.05;

	/**
		The first retransmission delay, in seconds, doubling from there.

		RFC 5389's RTO. A check has no failure to report -- a datagram that
		reaches nothing looks the same as one still in flight -- so a timer is
		the only thing that ever ends one.
	**/
	public static inline var INITIAL_RTO:Float = 0.5;

	/** Transmissions before a pair is given up on, RFC 5389's Rc. **/
	public static inline var MAX_ATTEMPTS:Int = 7;

	private static inline var TRANSACTION_LENGTH:Int = 12;

	/**
		Whether an agent can be created here at all.

		Every check carries a transaction id, and every agent a tiebreaker, both
		of which have to be unguessable -- so this is `SecureRandom` under a
		different name. A target without one can still use `IceCandidate` and
		the pairing, which is arithmetic; it cannot run an agent.
	**/
	public static var isSupported(default, null):Bool = SecureRandom.isSupported;

	/**
		Whether this peer decides which pair is used.

		Exactly one of the two must be. The roles are settled before the agent
		exists -- by an offer/answer exchange, or by whatever brought the peers
		together -- and if both claim it anyway, the tiebreakers resolve it.
	**/
	public var controlling(default, null):Bool;

	/** This peer's credentials, which the other side verifies checks against. **/
	public var localCredentials(default, null):IceCredentials;

	/** The other peer's, once `start` has been given them. **/
	public var remoteCredentials(default, null):Null<IceCredentials>;

	/** Random, 64 bits, and compared when two peers claim the same role. **/
	public var tiebreaker(default, null):Int64;

	public var state(default, null):IceAgentState = NEW;

	/** The pair traffic should use, once there is one. **/
	public var selectedPair(default, null):Null<IceCandidatePair>;

	/**
		Resolves with the nominated pair, or fails when every pair has.

		One shot: an agent that has connected stays connected until it is
		closed, and an ICE restart is a new agent rather than a second result
		on this one.
	**/
	public var connected(default, null):Future<IceCandidatePair>;

	/**
		Called with a datagram to put on the wire.

		The caller wires this to whatever socket the local candidates describe.
		It must be the socket those candidates name -- a check leaving from
		anywhere else opens a NAT mapping for a port the peer was never told
		about.
	**/
	public dynamic function onSend(payload:ByteArray, address:String, port:Int):Void {}

	@:noCompletion private var __locals:Array<IceCandidate> = [];
	@:noCompletion private var __remotes:Array<IceCandidate> = [];
	@:noCompletion private var __checks:Array<IceCheck> = [];
	@:noCompletion private var __valid:Array<IceCandidatePair> = [];
	@:noCompletion private var __nextCheckAt:Float = 0;
	@:noCompletion private var __nominating:Bool = false;

	/**
		@param controlling Whether this peer nominates. The two peers must pass
		opposite values.
		@param localCredentials This peer's own. Generated when omitted, which
		needs `isSupported`.
	**/
	public function new(controlling:Bool, ?localCredentials:IceCredentials, ?tiebreaker:Null<Int64>) {
		this.controlling = controlling;
		this.localCredentials = localCredentials != null ? localCredentials : IceCredentials.generate();
		this.tiebreaker = tiebreaker != null ? tiebreaker : __randomTiebreaker();
		this.connected = new Future<IceCandidatePair>();
	}

	/**
		Adds one of this peer's own addresses.

		Order does not matter, and candidates may arrive after checking has
		started -- gathering a reflexive address takes a round trip to a STUN
		server, and waiting for it before trying the host candidates would delay
		the case that needs no server at all.
	**/
	public function addLocalCandidate(candidate:IceCandidate):Void {
		if (candidate == null) {
			throw new ArgumentError("A candidate is required.");
		}

		if (!__known(__locals, candidate)) {
			__locals.push(candidate);
			__rebuild();
		}
	}

	/** Adds an address the other peer says it can be reached at. **/
	public function addRemoteCandidate(candidate:IceCandidate):Void {
		if (candidate == null) {
			throw new ArgumentError("A candidate is required.");
		}

		if (!__known(__remotes, candidate)) {
			__remotes.push(candidate);
			__rebuild();
		}
	}

	/**
		Begins checking.

		@param remoteCredentials The other peer's, which is what checks going
		out are signed with.
		@param now The current time, in seconds. Supplied rather than read so
		that the whole agent is driven by one clock the caller controls.
	**/
	public function start(remoteCredentials:IceCredentials, now:Float):Void {
		if (remoteCredentials == null) {
			throw new ArgumentError("The other peer's credentials are needed before a check can be signed.");
		}

		if (state != NEW) {
			return;
		}

		this.remoteCredentials = remoteCredentials;
		state = CHECKING;
		__nextCheckAt = now;
		__rebuild();
	}

	/**
		Moves time forward: sends what is due, retransmits what was not
		answered, gives up on what will not be.

		@param now The current time in seconds, from any monotonic-enough source
		the caller also uses for `receive`.
	**/
	public function poll(now:Float):Void {
		if (state != CHECKING) {
			return;
		}

		for (check in __checks) {
			if (check.state == IN_PROGRESS && now >= check.nextAttemptAt) {
				if (check.attempts >= MAX_ATTEMPTS) {
					// Nothing came back through seven transmissions over about
					// half a minute. The pair is not a path.
					check.state = FAILED;
				} else {
					__transmit(check, now);
				}
			}
		}

		if (now >= __nextCheckAt) {
			var next = __nextWaiting();

			if (next != null) {
				__transmit(next, now);
				__nextCheckAt = now + PACING;
			}
		}

		if (controlling && !__nominating && __valid.length > 0) {
			__nominate(now);
		}

		__settleIfFinished();
	}

	/**
		Offers an arriving datagram to the agent.

		@return Whether this was a STUN message the agent took. False means the
		datagram belongs to whatever else shares the socket, which is the normal
		case once a session is carrying data -- so a caller should pass it on
		rather than dropping it.
	**/
	public function receive(payload:ByteArray, fromAddress:String, fromPort:Int, now:Float):Bool {
		if (state == CLOSED || payload == null) {
			return false;
		}

		var message = StunMessage.decode(payload);

		if (message == null) {
			return false;
		}

		switch (message.type) {
			case StunMessage.BINDING_REQUEST:
				__answer(message, fromAddress, fromPort, now);
			case StunMessage.BINDING_SUCCESS:
				__accept(message, fromAddress, fromPort, now);
			default:
				// An error response, or something else entirely. It was still a
				// STUN message, so it is not the caller's to handle.
		}

		return true;
	}

	/** Stops everything. A closed agent neither sends nor answers. **/
	public function close():Void {
		if (state == CLOSED) {
			return;
		}

		state = CLOSED;
		__checks = [];
	}

	/** Every pair that has answered, best first. **/
	public function validPairs():Array<IceCandidatePair> {
		return __valid.copy();
	}

	// ------------------------------------------------------------------
	// Sending
	// ------------------------------------------------------------------

	@:noCompletion private function __transmit(check:IceCheck, now:Float):Void {
		if (remoteCredentials == null) {
			return;
		}

		var message = new StunMessage(StunMessage.BINDING_REQUEST, check.transaction, [
			StunMessage.username(IceCredentials.username(remoteCredentials, localCredentials)),
			// What this peer would give a peer-reflexive candidate the other
			// side learns from this check. Sent rather than left to be guessed,
			// so both still order the list the same way.
			StunMessage.priority(IceCandidate.computePriority(PEER_REFLEXIVE, IceCandidate.DEFAULT_LOCAL_PREFERENCE, check.pair.local.component)),
			StunMessage.iceRole(controlling, tiebreaker)
		]);

		if (check.nominate) {
			message.attributes.push(StunMessage.useCandidate());
		}

		check.state = IN_PROGRESS;
		check.attempts++;
		// Doubling from 500ms, so seven attempts span roughly 31 seconds.
		check.nextAttemptAt = now + INITIAL_RTO * Math.pow(2, check.attempts - 1);

		onSend(message.encodeSigned(remoteCredentials.password), check.pair.remote.address, check.pair.remote.port);
	}

	@:noCompletion private function __nominate(now:Float):Void {
		__nominating = true;

		// The best pair that has answered. Not merely the best pair: nominating
		// one that has not been checked would be choosing a path on the
		// strength of its priority rather than on its having worked.
		var best = __valid[0];
		var check = __checkFor(best);

		if (check == null) {
			check = __add(best);
		}

		check.nominate = true;
		check.attempts = 0;
		check.state = WAITING;
		__transmit(check, now);
	}

	// ------------------------------------------------------------------
	// Receiving
	// ------------------------------------------------------------------

	@:noCompletion private function __answer(request:StunMessage, fromAddress:String, fromPort:Int, now:Float):Void {
		var usernameBytes = request.attribute(StunMessage.ATTR_USERNAME);

		if (usernameBytes == null) {
			return;
		}

		usernameBytes.position = 0;
		var username = usernameBytes.readUTFBytes(usernameBytes.length);

		// Addressed to this peer, and signed with this peer's password -- which
		// is what makes it a check for this session rather than a stray
		// datagram or somebody else's.
		if (!localCredentials.addressedByUsername(username) || !request.verifyIntegrity(localCredentials.password)) {
			return;
		}

		var response = new StunMessage(StunMessage.BINDING_SUCCESS, request.transactionId, [
			// Where this peer sees the sender, which is how the sender learns
			// about a mapping its own NAT made and it could not have known.
			StunMessage.xorMappedAddress(fromAddress, fromPort)
		]);

		onSend(response.encodeSigned(localCredentials.password), fromAddress, fromPort);

		var pair = __pairFrom(fromAddress, fromPort);

		if (pair == null) {
			return;
		}

		var check = __checkFor(pair);

		if (check == null) {
			check = __add(pair);
		}

		// A triggered check. The peer has proved it is there and is asking; the
		// mapping in this direction is open now and may not be later, so this
		// pair goes to the front rather than waiting its turn.
		if (check.state == WAITING || check.state == FROZEN) {
			__transmit(check, now);
		}

		if (request.hasUseCandidate() && !controlling && check.state == SUCCEEDED) {
			__select(pair);
		} else if (request.hasUseCandidate() && !controlling) {
			// Nominated before this side finished confirming it. Remembered, so
			// selecting happens the moment the check answers.
			check.nominatedByPeer = true;
		}
	}

	@:noCompletion private function __accept(response:StunMessage, fromAddress:String, fromPort:Int, now:Float):Void {
		if (remoteCredentials == null) {
			return;
		}

		var check = __checkByTransaction(response);

		if (check == null || check.state != IN_PROGRESS) {
			return;
		}

		// Keyed with the other peer's password, the same one that signed the
		// request -- so a response nobody could have signed is not an answer.
		if (!response.verifyIntegrity(remoteCredentials.password)) {
			return;
		}

		check.state = SUCCEEDED;

		var mapped = response.mappedAddress();

		if (mapped != null && !__sameEndpoint(mapped, check.pair.local)) {
			// The peer saw this check arrive from somewhere this peer did not
			// know it could be reached: a mapping its NAT made for this
			// destination alone. That is a peer-reflexive candidate, and it is
			// often the only one that works.
			__learnPeerReflexive(mapped, check.pair.remote);
		}

		__addValid(check.pair);

		if (check.nominate || check.nominatedByPeer) {
			__select(check.pair);
		}

		__settleIfFinished();
	}

	@:noCompletion private function __learnPeerReflexive(mapped:ReflexiveAddress, remote:IceCandidate):Void {
		var discovered = new IceCandidate(PEER_REFLEXIVE, mapped.address, mapped.port, remote.component);

		if (!__known(__locals, discovered)) {
			__locals.push(discovered);
			__rebuild();
		}
	}

	// ------------------------------------------------------------------
	// Bookkeeping
	// ------------------------------------------------------------------

	@:noCompletion private function __rebuild():Void {
		if (state != CHECKING) {
			return;
		}

		for (pair in IceCandidatePair.pair(__locals, __remotes, controlling)) {
			if (__checkFor(pair) == null) {
				__add(pair);
			}
		}

		// Highest priority first, so `__nextWaiting` is a scan rather than a
		// search and the order the two peers agreed on is the order used.
		__checks.sort(function(a:IceCheck, b:IceCheck):Int {
			return Int64.compare(b.pair.priority, a.pair.priority);
		});
	}

	@:noCompletion private function __add(pair:IceCandidatePair):IceCheck {
		var check = new IceCheck(pair, __freshTransaction());
		__checks.push(check);
		return check;
	}

	@:noCompletion private function __nextWaiting():Null<IceCheck> {
		for (check in __checks) {
			if (check.state == WAITING || check.state == FROZEN) {
				return check;
			}
		}

		return null;
	}

	@:noCompletion private function __checkFor(pair:IceCandidatePair):Null<IceCheck> {
		for (check in __checks) {
			if (check.pair.sameAs(pair)) {
				return check;
			}
		}

		return null;
	}

	@:noCompletion private function __checkByTransaction(response:StunMessage):Null<IceCheck> {
		for (check in __checks) {
			// Byte for byte against the request that was sent. A response is
			// otherwise just a datagram claiming to be one.
			if (new StunMessage(StunMessage.BINDING_REQUEST, check.transaction).matches(response)) {
				return check;
			}
		}

		return null;
	}

	/**
		The pair a check from `address:port` belongs to, creating the remote
		half when it is somewhere the peer never advertised.

		A check can arrive from a mapping the sending peer did not know it had,
		which is the same discovery this side makes from a response -- seen from
		the other end.
	**/
	@:noCompletion private function __pairFrom(address:String, port:Int):Null<IceCandidatePair> {
		var remote:IceCandidate = null;

		for (candidate in __remotes) {
			if (candidate.address == address && candidate.port == port) {
				remote = candidate;
				break;
			}
		}

		if (remote == null) {
			remote = new IceCandidate(PEER_REFLEXIVE, address, port);
			__remotes.push(remote);
		}

		// The local half is this peer's best candidate that could reach it. One
		// socket serves every local candidate here, so which is named affects
		// the priority and nothing about where the datagram goes.
		for (local in __locals) {
			if (local.canReach(remote)) {
				return new IceCandidatePair(local, remote, controlling);
			}
		}

		return null;
	}

	@:noCompletion private function __addValid(pair:IceCandidatePair):Void {
		for (existing in __valid) {
			if (existing.sameAs(pair)) {
				return;
			}
		}

		__valid.push(pair);
		__valid.sort(function(a:IceCandidatePair, b:IceCandidatePair):Int {
			return Int64.compare(b.priority, a.priority);
		});
	}

	@:noCompletion private function __select(pair:IceCandidatePair):Void {
		if (state == CONNECTED || state == CLOSED) {
			return;
		}

		selectedPair = pair;
		state = CONNECTED;
		@:privateAccess connected.__resolve(pair);
	}

	@:noCompletion private function __settleIfFinished():Void {
		if (state != CHECKING || __checks.length == 0) {
			return;
		}

		for (check in __checks) {
			if (check.state != FAILED) {
				return;
			}
		}

		state = FAILED;
		@:privateAccess connected.__fail("Every candidate pair failed: no path between these two peers was found.", null);
	}

	@:noCompletion private function __sameEndpoint(mapped:ReflexiveAddress, candidate:IceCandidate):Bool {
		return mapped.address == candidate.address && mapped.port == candidate.port;
	}

	@:noCompletion private static function __known(candidates:Array<IceCandidate>, candidate:IceCandidate):Bool {
		for (existing in candidates) {
			if (existing.sameAs(candidate)) {
				return true;
			}
		}

		return false;
	}

	@:noCompletion private static function __freshTransaction():ByteArray {
		return SecureRandom.getSecureRandomBytes(TRANSACTION_LENGTH);
	}

	@:noCompletion private static function __randomTiebreaker():Int64 {
		var bytes:ByteArray = SecureRandom.getSecureRandomBytes(8);
		bytes.endian = crossbyte.io.Endian.BIG_ENDIAN;
		bytes.position = 0;
		return Int64.make(bytes.readInt(), bytes.readInt());
	}
}

/** One pair, and where its checking has got to. */
private class IceCheck {
	public var pair:IceCandidatePair;
	public var transaction:ByteArray;
	public var state:IceCandidatePairState = WAITING;
	public var attempts:Int = 0;
	public var nextAttemptAt:Float = 0;

	/** Whether this peer is asking for this pair to be the one used. **/
	public var nominate:Bool = false;

	/** Whether the other peer asked for it before this side had confirmed it. **/
	public var nominatedByPeer:Bool = false;

	public function new(pair:IceCandidatePair, transaction:ByteArray) {
		this.pair = pair;
		this.transaction = transaction;
	}
}
