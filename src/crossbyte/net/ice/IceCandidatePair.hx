package crossbyte.net.ice;

import crossbyte.errors.ArgumentError;
import haxe.Int64;

/**
	One of this peer's candidates matched against one of the other peer's, and
	the order the two of them will try it in.

	ICE does not negotiate an address, it races them. Each side pairs everything
	it has against everything it was told about, sorts the pairs, and works down
	the list sending checks until one answers. The point of the sort is that
	both peers do it and both arrive at the same order -- the checks are cheap,
	but they are not free, and two peers working the list in different orders
	would spend them on different pairs.

	```haxe
	var pairs = IceCandidatePair.pair(mine, theirs, controlling);
	for (candidate in pairs) {
		// highest priority first
	}
	```

	## Which side is controlling

	The formula is asymmetric, so the two peers must agree on who is who before
	either can compute it. ICE settles that with the ICE-CONTROLLING and
	ICE-CONTROLLED attributes and a tiebreaker; here it is a flag the caller
	passes, because whatever decides it lives above this class. What matters is
	that the two peers pass opposite values -- if both claim to be controlling,
	both compute a valid ordering and they are different orderings.
**/
class IceCandidatePair {
	/** This peer's half. Checks are sent from here. **/
	public var local(default, null):IceCandidate;

	/** The other peer's half. Checks are sent to here. **/
	public var remote(default, null):IceCandidate;

	/** Whether this peer was the controlling one when the priority was worked out. **/
	public var controlling(default, null):Bool;

	/**
		What the list is sorted by, descending.

		An `Int64` rather than an `Int` because the formula genuinely needs one:
		see `computePriority`.
	**/
	public var priority(default, null):Int64;

	/**
		@throws ArgumentError if the two candidates cannot be paired at all --
		different components, or different address families.
	**/
	public function new(local:IceCandidate, remote:IceCandidate, controlling:Bool) {
		if (local == null || remote == null) {
			throw new ArgumentError("A candidate pair needs both halves.");
		}

		if (!local.canReach(remote)) {
			throw new ArgumentError("These candidates cannot be paired: " + local + " and " + remote
				+ " differ in component or address family, so no packet could travel between them.");
		}

		this.local = local;
		this.remote = remote;
		this.controlling = controlling;
		this.priority = computePriority(local.priority, remote.priority, controlling);
	}

	/**
		RFC 8445 section 6.1.2.3, where G is the controlling peer's candidate
		priority and D is the controlled peer's:

		    pair priority = 2^32 * MIN(G, D)
		                  + 2    * MAX(G, D)
		                  + (G > D ? 1 : 0)

		Both peers compute this over the same two numbers and must agree, which
		is what the shape buys. The smaller of the two dominates, so a pair is
		worth no more than its weaker half -- there is no use in one peer
		offering a superb address if the other end of the pair is a relay. The
		larger breaks ties among pairs whose weaker halves match. The final bit
		exists only so that the two orderings a swapped G and D would produce
		cannot collide.

		It does not fit in 32 bits and is not meant to: `MIN` can be as large as
		2130706431, and multiplying that by 2^32 gives about 9.15e18 against an
		`Int64` ceiling of 9.22e18. The RFC picked exponents that fill a signed
		64-bit integer almost exactly, so this is `Int64` everywhere rather than
		an `Int` that happens to work on targets whose numbers are doubles.
	**/
	public static function computePriority(localPriority:Int, remotePriority:Int, controlling:Bool):Int64 {
		var g:Int = controlling ? localPriority : remotePriority;
		var d:Int = controlling ? remotePriority : localPriority;

		var min:Int64 = Int64.ofInt(g < d ? g : d);
		var max:Int64 = Int64.ofInt(g > d ? g : d);

		// Int64.make(1, 0) is 2^32: one in the high word, nothing in the low.
		return min * Int64.make(1, 0) + Int64.ofInt(2) * max + Int64.ofInt(g > d ? 1 : 0);
	}

	/**
		Every pair worth trying, best first.

		Candidates that cannot reach each other are left out rather than
		included and failed later, and a candidate repeated within either list
		is counted once -- the same address discovered as a host candidate and
		again through STUN is one place, and checking it twice would spend a
		check to learn nothing.

		## Reflexive candidates pair as their base

		Nothing can send *from* a reflexive address. It is where a NAT put this
		peer, learned by asking, and a datagram aimed at a peer still leaves the
		socket the question went out of -- so RFC 8445 section 6.1.2.2 replaces
		a reflexive local candidate with its base when forming pairs, and
		section 6.1.2.4 then drops any pair left redundant: same local base,
		same remote.

		This is not a nicety. A peer that gathers a reflexive address has, for
		every remote candidate, one pair through the host and one through the
		reflexive view of it -- and with a single socket both send the same
		datagram to the same place. Pairing by base collapses them, and the
		higher-priority pair is the one kept, which is the host.

		A reflexive candidate still earns its place: it is what the *peer* is
		told to aim at, and pruning here changes nothing about what `description`
		advertises. What it decides is only which checks this peer sends.

		A relayed candidate is not collapsed. RFC 8445 section 5.1.1.2 makes it
		its own base, because a relay lends an address that really does send --
		it is a path in its own right rather than another view of one.

		A reflexive candidate whose base was never recorded is left alone, since
		pruning by a base that was guessed rather than known would drop pairs
		that were not redundant.

		@param controlling Whether this peer is the controlling one. The two
		peers must pass opposite values, or they will sort the same pairs
		differently.
	**/
	public static function pair(locals:Array<IceCandidate>, remotes:Array<IceCandidate>, controlling:Bool):Array<IceCandidatePair> {
		var pairs:Array<IceCandidatePair> = [];

		if (locals == null || remotes == null) {
			return pairs;
		}

		var localsOnce = __distinct(locals);
		var remotesOnce = __distinct(remotes);

		for (local in localsOnce) {
			for (remote in remotesOnce) {
				if (local.canReach(remote)) {
					// The base, so a reflexive candidate is checked as the
					// address that actually sends. RFC 8445 ranks the pair by
					// the candidate as gathered and substitutes afterwards;
					// ranking the substituted pair reaches the same order, since
					// the pair that survives a collapse is the highest of them
					// and the highest is the base itself.
					pairs.push(new IceCandidatePair(local.baseOrSelf(), remote, controlling));
				}
			}
		}

		// Descending: the highest priority is tried first. Int64.compare rather
		// than a subtraction, which would overflow the Int the sort wants back.
		pairs.sort(function(a:IceCandidatePair, b:IceCandidatePair):Int {
			return Int64.compare(b.priority, a.priority);
		});

		return __pruned(pairs);
	}

	/**
		Whether this and `other` would send the same check to the same place.

		The pair is the same when both halves are, which is what makes a
		duplicate worth dropping.
	**/
	public function sameAs(other:IceCandidatePair):Bool {
		if (other == null) {
			return false;
		}

		return local.sameAs(other.local) && remote.sameAs(other.remote);
	}

	public function toString():String {
		return local + " -> " + remote + " (pair priority " + Int64.toStr(priority) + ")";
	}

	/**
		Drops every pair a higher-priority one already covers.

		Sorted first, so the first pair seen for a given local and remote is the
		best of them and the rest are the redundant ones. Two pairs match when
		their locals are the same place and their remotes are -- which after the
		substitution above means a host pair and the reflexive pair that
		collapsed onto it.
	**/
	@:noCompletion private static function __pruned(pairs:Array<IceCandidatePair>):Array<IceCandidatePair> {
		var kept:Array<IceCandidatePair> = [];

		for (pair in pairs) {
			var redundant = false;

			for (existing in kept) {
				if (existing.local.sameAs(pair.local) && existing.remote.sameAs(pair.remote)) {
					redundant = true;
					break;
				}
			}

			if (!redundant) {
				kept.push(pair);
			}
		}

		return kept;
	}

	@:noCompletion private static function __distinct(candidates:Array<IceCandidate>):Array<IceCandidate> {
		var unique:Array<IceCandidate> = [];

		for (candidate in candidates) {
			if (candidate == null) {
				continue;
			}

			var seen = false;

			for (kept in unique) {
				if (kept.sameAs(candidate)) {
					seen = true;
					break;
				}
			}

			if (!seen) {
				unique.push(candidate);
			}
		}

		return unique;
	}
}
