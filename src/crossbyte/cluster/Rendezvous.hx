package crossbyte.cluster;

import crossbyte.errors.ArgumentError;
import haxe.crypto.Crc32;
import haxe.io.Bytes;

/**
	Which node owns a key, agreed without anyone being asked.

	Every node runs the same arithmetic over the same membership and reaches
	the same answer, so a key's owner needs no lookup service and no
	coordination -- only that the nodes agree on who is alive, which is what
	membership is for.

	Highest random weight: each candidate is scored against the key and the
	best score wins. Removing a node moves only the keys that node held, and
	adding one takes only its share from each of the others -- which is the
	property that matters, because every key that moves is state that has to
	be rebuilt somewhere.

	Preferred to a hash ring because there is nothing to tune. A ring spreads
	load evenly only when each node is spread over enough virtual points, and
	choosing how many is a judgement that has to be revisited as the cluster
	grows. This has no such number.

	```haxe
	var ring = new Rendezvous();
	ring.add("node-a");
	ring.add("node-b");

	var owner = ring.owner(roomId);            // one node
	var holders = ring.owners(roomId, 2);      // and its backup
	```

	Lookup is a pass over the membership, so it is meant for the tens or
	hundreds of nodes a cluster has, not for the number of keys it holds.
**/
class Rendezvous {
	/** How many nodes are in the membership. **/
	public var length(get, never):Int;

	private var __nodes:Array<String> = [];
	private var __hashes:Array<Int> = [];

	public function new() {}

	/**
		Adds a node.

		@return Whether it was new. Adding one already there changes nothing,
		        which matters because membership arrives repeatedly.
	**/
	public function add(node:String):Bool {
		if (node == null || node == "") {
			throw new ArgumentError("A node needs a name.");
		}

		if (__nodes.indexOf(node) >= 0) {
			return false;
		}

		__nodes.push(node);
		__hashes.push(hash(node));
		return true;
	}

	/** Removes a node. @return Whether it was there. **/
	public function remove(node:String):Bool {
		var at:Int = __nodes.indexOf(node);

		if (at < 0) {
			return false;
		}

		__nodes.splice(at, 1);
		__hashes.splice(at, 1);
		return true;
	}

	public function has(node:String):Bool {
		return __nodes.indexOf(node) >= 0;
	}

	/** The membership, in no particular order. **/
	public function nodes():Array<String> {
		return __nodes.copy();
	}

	public function clear():Void {
		__nodes = [];
		__hashes = [];
	}

	/**
		The node that owns this key, or null when there is no membership.

		Every node computes this the same way from the same membership, so
		two of them asked at the same moment give the same answer.
	**/
	public function owner(key:String):Null<String> {
		if (__nodes.length == 0) {
			return null;
		}

		var keyHash:Int = hash(key);
		var bestAt:Int = 0;
		var best:Int = weigh(keyHash, __hashes[0]);

		for (i in 1...__nodes.length) {
			var score:Int = weigh(keyHash, __hashes[i]);

			// Ties broken by name, so the answer does not depend on the
			// order membership happened to arrive in.
			if (score > best || (score == best && __nodes[i] > __nodes[bestAt])) {
				best = score;
				bestAt = i;
			}
		}

		return __nodes[bestAt];
	}

	/**
		The `count` best nodes for this key, best first.

		For anything held in more than one place: the first is the owner and
		the rest are where it goes next, in an order every node agrees on.
		Returns fewer than asked for when the membership is smaller.
	**/
	public function owners(key:String, count:Int):Array<String> {
		if (count <= 0 || __nodes.length == 0) {
			return [];
		}

		var keyHash:Int = hash(key);
		var ranked:Array<{node:String, score:Int}> = [];

		for (i in 0...__nodes.length) {
			ranked.push({node: __nodes[i], score: weigh(keyHash, __hashes[i])});
		}

		ranked.sort(function(a, b):Int {
			if (a.score != b.score) {
				return b.score - a.score > 0 ? 1 : -1;
			}

			return a.node < b.node ? 1 : (a.node > b.node ? -1 : 0);
		});

		var out:Array<String> = [];

		for (i in 0...(count < ranked.length ? count : ranked.length)) {
			out.push(ranked[i].node);
		}

		return out;
	}

	private function get_length():Int {
		return __nodes.length;
	}

	// ------------------------------------------------------------------

	/**
		A node's or key's hash.

		CRC32 because it is defined the same way everywhere. A multiply-based
		hash is faster and is not portable here: the constants overflow what
		a `Float` holds exactly before `| 0` can wrap them, so js and the
		static targets disagree -- and two nodes that disagree about a hash
		disagree about who owns a key, which is the one thing this may not do.
	**/
	private static inline function hash(value:String):Int {
		return Crc32.make(Bytes.ofString(value));
	}

	/**
		How well a node suits a key.

		The mixing has to be strong, not merely deterministic. An xorshift
		over the two hashes is a permutation with weak avalanche, and a
		permutation of a XOR is not enough to decorrelate the scores: with
		eight nodes it gave one of them twice its share of the keys and two
		others half, which is a cluster with a hot node in it.

		This is murmur3's finalizer, which avalanches properly.
	**/
	private static inline function weigh(keyHash:Int, nodeHash:Int):Int {
		var h:Int = keyHash ^ nodeHash;
		h = imul(h ^ (h >>> 16), 0x85EBCA6B);
		h = imul(h ^ (h >>> 13), 0xC2B2AE35);
		h ^= h >>> 16;
		// Unsigned, so comparisons order the same way regardless of the sign
		// bit the mixing happened to leave.
		return h >>> 1;
	}

	/**
		Thirty two bit multiply, the same on every target.

		`a * b` is not it. On js the product is a `Float` and anything past
		2^53 has already lost the low bits `| 0` would keep, so js and the
		static targets disagree -- and two nodes that disagree about a score
		disagree about who owns a key. Multiplying in halves keeps every
		partial product inside what a `Float` holds exactly.
	**/
	private static inline function imul(a:Int, b:Int):Int {
		var aLow:Int = a & 0xFFFF;
		var aHigh:Int = (a >>> 16) & 0xFFFF;
		var bLow:Int = b & 0xFFFF;
		var bHigh:Int = (b >>> 16) & 0xFFFF;

		return ((aLow * bLow) + ((((aLow * bHigh + aHigh * bLow) & 0xFFFF) << 16))) | 0;
	}
}
