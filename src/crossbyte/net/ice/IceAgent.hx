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

	/**
		How often consent to keep sending is re-asked for. RFC 7675 section 5.1.

		Randomised around this rather than sent on the dot, because a fixed
		interval means every agent on a network asks at the same moment.
	**/
	public static inline var CONSENT_INTERVAL:Float = 5.0;

	/**
		How long a selected pair may go unanswered before it stops being a path.

		RFC 7675 exists because a NAT mapping outlives nothing in particular: a
		peer can vanish, or its address can be handed to somebody else, and a
		sender with no way to notice keeps transmitting at a stranger. Thirty
		seconds is the figure the RFC gives.
	**/
	public static inline var CONSENT_TIMEOUT:Float = 30.0;

	/**
		The most remote candidates one agent will hold.

		Every remote candidate pairs with every local one, and `__rebuild`
		scans the whole checklist for each pair it considers, so the work grows
		faster than the list does -- and the list is the peer's to choose. A
		real peer offers a handful; RFC 8445 section 6.1.2.5 bounds the
		checklist for the same reason.
	**/
	public static inline var MAX_REMOTE_CANDIDATES:Int = 64;

	/**
		The refusal one peer sends when both claim the same role, RFC 8445
		section 7.3.1.1.
	**/
	public static inline var ROLE_CONFLICT:Int = 487;

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

	/**
		Fires when a role conflict made this agent change sides.

		Worth surfacing rather than hiding: every pair priority is computed from
		the role, so the order this agent works its list in has just changed,
		and a caller tracking which peer is expected to nominate now has it the
		other way round.
	**/
	public dynamic function onRoleChanged(controlling:Bool):Void {}

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

	/** How to send from a candidate that is not simply the shared socket. **/
	@:noCompletion private var __senders:Array<{candidate:IceCandidate, send:(ByteArray, String, Int) -> Void}> = [];

	/** Which candidate the datagram being handled arrived on, if not the socket. **/
	@:noCompletion private var __arrivedVia:IceCandidate = null;
	@:noCompletion private var __remotes:Array<IceCandidate> = [];
	@:noCompletion private var __checks:Array<IceCheck> = [];

	/** The consent check waiting for an answer, if one is. **/
	@:noCompletion private var __consentTransaction:ByteArray = null;

	/** When the next consent check is due. **/
	@:noCompletion private var __consentDueAt:Float = 0;

	/** When the peer last proved it is still there. **/
	@:noCompletion private var __consentedAt:Float = 0;
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

		@param send How to send from this candidate, when that is not simply the
		socket `onSend` writes to. A relayed candidate is the case that needs it:
		its address belongs to a TURN server, and reaching a peer through it means
		wrapping the datagram for the relay to forward rather than addressing the
		peer directly. Host and reflexive candidates share the one socket and want
		nothing here.

		The alternative would be for `onSend` to say which candidate a datagram is
		leaving from and let the caller sort it out. That puts the routing table in
		every caller; this keeps it where the knowledge already is, since whoever
		obtained a relayed address is the only thing that knows how to use it.
	**/
	public function addLocalCandidate(candidate:IceCandidate, ?send:(ByteArray, String, Int) -> Void):Void {
		if (candidate == null) {
			throw new ArgumentError("A candidate is required.");
		}

		if (send != null) {
			__senders.push({candidate: candidate, send: send});
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

		if (__known(__remotes, candidate)) {
			return;
		}

		// Dropped rather than refused: these arrive from the peer's
		// description, and one over-generous peer is not a reason to throw
		// into the application that relayed it.
		if (__remotes.length >= MAX_REMOTE_CANDIDATES) {
			return;
		}

		__remotes.push(candidate);
		__rebuild();
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
		if (state == CONNECTED) {
			__pollConsent(now);
			return;
		}

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
	public function receive(payload:ByteArray, fromAddress:String, fromPort:Int, now:Float, ?via:IceCandidate):Bool {
		if (state == CLOSED || payload == null) {
			return false;
		}

		var message = StunMessage.decode(payload);

		if (message == null) {
			return false;
		}

		// An answer has to leave the way the request arrived. A check that came
		// through a relay came from a peer with no other path here, and replying
		// straight back at the address it appears to be from sends the answer
		// somewhere it will be dropped -- while the request itself looked
		// perfectly ordinary, having been unwrapped before it got here.
		var previous = __arrivedVia;
		__arrivedVia = via;

		switch (message.type) {
			case StunMessage.BINDING_REQUEST:
				__answer(message, fromAddress, fromPort, now);
			case StunMessage.BINDING_SUCCESS:
				// Consent first: its transaction is not in __checks, so
				// __accept would look straight past it.
				if (!__acceptConsent(message, now)) {
					__accept(message, fromAddress, fromPort, now);
				}
			case StunMessage.BINDING_ERROR:
				__refused(message, now);
			default:
				// Something else entirely. It was still a STUN message, so it is
				// not the caller's to handle.
		}

		__arrivedVia = previous;
		return true;
	}

	/** Stops everything. A closed agent neither sends nor answers. **/
	public function close():Void {
		if (state == CLOSED) {
			return;
		}

		state = CLOSED;
		__checks = [];

		// A caller waiting on `connected` when the agent is closed under it
		// would otherwise wait forever. Nothing else settles this: the only
		// other failure path is __settleIfFinished, which decides by looking
		// at the checks -- and the line above just emptied them, so after a
		// close it can never conclude anything. Future.__fail is idempotent,
		// so an agent that already found a path keeps its result.
		@:privateAccess connected.__fail("The agent was closed before a path was found.", null);
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
		// Recorded, because a refusal that comes back may be answering a claim
		// this agent has since abandoned. See __refused.
		check.sentAsControlling = controlling;
		// Doubling from 500ms, so seven attempts span roughly 31 seconds.
		check.nextAttemptAt = now + INITIAL_RTO * Math.pow(2, check.attempts - 1);

		__sendVia(check.pair.local, message.encodeSigned(remoteCredentials.password), check.pair.remote.address, check.pair.remote.port);
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

		// Before answering: the sender may have claimed the same role this
		// agent holds, and one of the two has to give way before either can
		// trust the ordering it computed.
		if (__resolveRoleConflict(request)) {
			var refusal = new StunMessage(StunMessage.BINDING_ERROR, request.transactionId, [
				StunMessage.errorCode(ROLE_CONFLICT, "Role Conflict")
			]);

			__sendVia(__arrivedVia, refusal.encodeSigned(localCredentials.password), fromAddress, fromPort);
			return;
		}

		var response = new StunMessage(StunMessage.BINDING_SUCCESS, request.transactionId, [
			// Where this peer sees the sender, which is how the sender learns
			// about a mapping its own NAT made and it could not have known.
			StunMessage.xorMappedAddress(fromAddress, fromPort)
		]);

		__sendVia(__arrivedVia, response.encodeSigned(localCredentials.password), fromAddress, fromPort);

		var pair = __pairFrom(fromAddress, fromPort, __arrivedVia);

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
			__select(pair, now);
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
			__learnPeerReflexive(mapped, check.pair.remote, check.pair.local);
		}

		__addValid(check.pair);

		if (check.nominate || check.nominatedByPeer) {
			__select(check.pair, now);
		}

		__settleIfFinished();
	}

	/**
		Settles two peers who both claim the same role, RFC 8445 section
		7.3.1.1.

		This is not a defensive check against a broken peer. Roles are agreed
		out of band, and any exchange that can be raced -- both sides offering
		at once, a restart, a signalling path that reordered two messages -- can
		leave both convinced they are controlling. Nothing detects that until a
		check arrives, because until then each side is internally consistent.

		The larger tiebreaker keeps the role it claimed. What differs between
		the two cases is who acts: a controlling agent that loses switches
		itself, while a controlling agent that wins refuses the check and makes
		the *sender* switch. That asymmetry is the whole mechanism -- both peers
		apply the same comparison to the same two numbers and exactly one of
		them moves.

		@return Whether to refuse this check with a 487 rather than answer it.
	**/
	@:noCompletion private function __resolveRoleConflict(request:StunMessage):Bool {
		var claim = request.iceRoleClaim();

		if (claim == null || claim.controlling != controlling) {
			// No claim, or the two disagree about who is what, which is the
			// arrangement that works.
			return false;
		}

		var wins = Int64.compare(tiebreaker, claim.tiebreaker) >= 0;

		if (controlling) {
			// Both controlling. The larger keeps it and refuses; the smaller
			// gives way.
			if (wins) {
				return true;
			}

			__switchRole();
			return false;
		}

		// Both controlled, which is the mirror: the larger takes the role
		// rather than keeping it, and the smaller refuses so the sender takes
		// it instead.
		if (wins) {
			__switchRole();
			return false;
		}

		return true;
	}

	/**
		A check this agent sent was refused.

		The only refusal acted on is a role conflict, and acting on it means
		changing sides and asking again -- with a new transaction, because the
		old one has been answered and a peer is entitled to ignore a repeat of
		it.
	**/
	@:noCompletion private function __refused(response:StunMessage, now:Float):Void {
		var check = __checkByTransaction(response);

		if (check == null || remoteCredentials == null) {
			return;
		}

		if (!response.verifyIntegrity(remoteCredentials.password)) {
			return;
		}

		if (response.errorCodeValue() != ROLE_CONFLICT) {
			// Any other refusal is this pair failing, not the session.
			check.state = FAILED;
			__settleIfFinished();
			return;
		}

		// Only if this refusal is about the role currently held. A check sent
		// while claiming to be controlling can be refused *after* an inbound
		// check has already made this agent controlled, and acting on that
		// stale answer puts it straight back into the conflict it just left.
		//
		// Measured without this guard: the two still converge, but the role
		// changes more than once, and every change throws away the priority of
		// every pair and the nomination in progress. So the cost is round trips
		// and churn rather than deadlock -- which is worse to diagnose, because
		// it looks like it works. Retried under the new role instead, which is
		// what the refusal was asking for.
		if (check.sentAsControlling == controlling) {
			__switchRole();
		}

		check.transaction = __freshTransaction();
		check.attempts = 0;
		check.state = WAITING;
		__transmit(check, now);
	}

	/**
		Changes sides, and rebuilds everything that depended on the old one.

		Pair priority is computed from the role, so every pair this agent holds
		is now carrying a number both peers would no longer agree on. Rebuilding
		them rather than leaving them is the difference between switching roles
		and merely relabelling: the point of the switch is that the two peers go
		back to sorting the same list the same way.

		Progress is kept. A pair that has already answered is a path that
		demonstrably works, and that fact does not depend on who is nominating.
	**/
	@:noCompletion private function __switchRole():Void {
		controlling = !controlling;

		for (check in __checks) {
			check.pair = new IceCandidatePair(check.pair.local, check.pair.remote, controlling);
		}

		var revalued:Array<IceCandidatePair> = [];

		for (pair in __valid) {
			revalued.push(new IceCandidatePair(pair.local, pair.remote, controlling));
		}

		__valid = revalued;
		__valid.sort(function(a:IceCandidatePair, b:IceCandidatePair):Int {
			return Int64.compare(b.priority, a.priority);
		});

		__checks.sort(function(a:IceCheck, b:IceCheck):Int {
			return Int64.compare(b.pair.priority, a.pair.priority);
		});

		if (selectedPair != null) {
			selectedPair = new IceCandidatePair(selectedPair.local, selectedPair.remote, controlling);
		}

		// A newly controlling agent has a nomination to make; a newly controlled
		// one must not make the one it had started.
		__nominating = false;

		onRoleChanged(controlling);
	}

	/**
		Sends from a particular candidate.

		Falls back to `onSend` for every candidate that shares the socket, which
		is all of them but a relayed one.
	**/
	@:noCompletion private function __sendVia(via:IceCandidate, payload:ByteArray, address:String, port:Int):Void {
		if (via != null) {
			for (entry in __senders) {
				if (entry.candidate.sameAs(via)) {
					entry.send(payload, address, port);
					return;
				}
			}
		}

		onSend(payload, address, port);
	}

	@:noCompletion private function __learnPeerReflexive(mapped:ReflexiveAddress, remote:IceCandidate, base:IceCandidate):Void {
		// The base is the candidate the check went out from, which is what a
		// peer's view of this agent is a view *of*. Without it the discovered
		// address would pair as a place of its own and every check would go out
		// twice from the one socket.
		var discovered = new IceCandidate(PEER_REFLEXIVE, mapped.address, mapped.port, remote.component, null,
			IceCandidate.DEFAULT_LOCAL_PREFERENCE, base);

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
	@:noCompletion private function __pairFrom(address:String, port:Int, ?via:IceCandidate):Null<IceCandidatePair> {
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

		// The local half is whichever of this peer's addresses the request came
		// in on, when that is known. It used to be simply the first that could
		// reach the remote at all, on the reasoning that one socket serves every
		// local candidate so the choice moved the priority and nothing else.
		//
		// A relayed candidate breaks that. Its address belongs to a server, and
		// naming it is what decides a datagram gets wrapped for that server to
		// forward rather than addressed at the peer directly -- so a check that
		// arrived through a relay and was answered on a host candidate would go
		// straight out at an address the peer is not reachable at, while looking
		// from here like an ordinary triggered check.
		if (via != null) {
			for (local in __locals) {
				if (local.sameAs(via) && local.canReach(remote)) {
					return new IceCandidatePair(local, remote, controlling);
				}
			}
		}

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

	/**
		Keeps asking whether the peer is still willing to be sent to.

		RFC 7675. ICE proves a path once, and nothing about that proof stays
		true: the peer can vanish, and its address can be reassigned to
		somebody else who never agreed to hear from this one. So a selected
		pair is re-confirmed on a timer, and a pair that stops answering stops
		being a path.
	**/
	@:noCompletion private function __pollConsent(now:Float):Void {
		if (selectedPair == null || remoteCredentials == null) {
			return;
		}

		if (now - __consentedAt >= CONSENT_TIMEOUT) {
			// FAILED rather than a callback, because a hook nothing is obliged
			// to read is a way of not reporting this. `selectedPair` is left
			// alone: it is what the path *was*, which is worth having when
			// working out why a session stopped.
			state = FAILED;
			__consentTransaction = null;
			return;
		}

		if (now < __consentDueAt) {
			return;
		}

		__sendConsent(now);
	}

	/**
		One consent check on the selected pair.

		An ordinary connectivity check in every respect but one: never
		USE-CANDIDATE. This asks whether the peer is still there, and
		nominating a pair that is already selected is a second nomination for
		the far side to reconcile.
	**/
	@:noCompletion private function __sendConsent(now:Float):Void {
		__consentTransaction = __freshTransaction();

		var message = new StunMessage(StunMessage.BINDING_REQUEST, __consentTransaction, [
			StunMessage.username(IceCredentials.username(remoteCredentials, localCredentials)),
			StunMessage.priority(IceCandidate.computePriority(PEER_REFLEXIVE, IceCandidate.DEFAULT_LOCAL_PREFERENCE,
				selectedPair.local.component)),
			StunMessage.iceRole(controlling, tiebreaker)
		]);

		__sendVia(selectedPair.local, message.encodeSigned(remoteCredentials.password), selectedPair.remote.address,
			selectedPair.remote.port);

		// Spread across 0.8 to 1.2 of the interval, which the RFC asks for so
		// that a network full of agents does not ask in one burst. It also
		// keeps the rate under the one-every-four-seconds ceiling it sets.
		__consentDueAt = now + CONSENT_INTERVAL * (0.8 + 0.4 * Math.random());
	}

	/**
		Whether this response answers the consent check in flight.

		@return `true` when it did, so the caller stops looking.
	**/
	@:noCompletion private function __acceptConsent(response:StunMessage, now:Float):Bool {
		if (__consentTransaction == null || remoteCredentials == null) {
			return false;
		}

		if (!new StunMessage(StunMessage.BINDING_REQUEST, __consentTransaction).matches(response)) {
			return false;
		}

		// Signed with the peer's password, like every other answer here.
		// Without this an off-path sender could hold the path open by
		// guessing, which is the opposite of what consent is for.
		if (!response.verifyIntegrity(remoteCredentials.password)) {
			return false;
		}

		__consentTransaction = null;
		__consentedAt = now;
		return true;
	}

	@:noCompletion private function __select(pair:IceCandidatePair, now:Float):Void {
		if (state == CONNECTED || state == CLOSED) {
			return;
		}

		selectedPair = pair;
		state = CONNECTED;

		// Consent starts fresh here rather than at zero: the check that
		// nominated this pair was answered, which is the same question a
		// consent check asks. Starting at zero would expire the path instantly
		// on any clock already past CONSENT_TIMEOUT.
		__consentedAt = now;
		__consentDueAt = now + CONSENT_INTERVAL;

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
	/** Reassigned when the role changes, since its priority is computed from it. **/
	public var pair:IceCandidatePair;
	public var transaction:ByteArray;
	public var state:IceCandidatePairState = WAITING;
	public var attempts:Int = 0;
	public var nextAttemptAt:Float = 0;

	/**
		The role claimed when this check last went out.

		Kept so a refusal arriving after the role already changed can be told
		from one that is still current.
	**/
	public var sentAsControlling:Bool = false;

	/** Whether this peer is asking for this pair to be the one used. **/
	public var nominate:Bool = false;

	/** Whether the other peer asked for it before this side had confirmed it. **/
	public var nominatedByPeer:Bool = false;

	public function new(pair:IceCandidatePair, transaction:ByteArray) {
		this.pair = pair;
		this.transaction = transaction;
	}
}
