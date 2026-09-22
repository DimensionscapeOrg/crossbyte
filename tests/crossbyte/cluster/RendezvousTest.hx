package crossbyte.cluster;

import utest.Assert;

/**
	Which node owns a key, agreed without anyone being asked.

	Pure arithmetic, so every target runs these -- and two targets disagreeing
	would be two nodes disagreeing about who owns a key, which is the one
	thing this may not do.
**/
class RendezvousTest extends utest.Test {
	/** The same key and membership give the same owner, every time. **/
	public function testTheSameMembershipAlwaysGivesTheSameOwner():Void {
		var one = ring(["a", "b", "c", "d"]);
		// Added in a different order, which must not matter.
		var two = ring(["d", "c", "b", "a"]);
		var disagreements:Int = 0;

		for (i in 0...500) {
			if (one.owner("room-" + i) != two.owner("room-" + i)) {
				disagreements++;
			}
		}

		Assert.equals(0, disagreements, "two nodes with the same membership disagreed " + disagreements + " times");
	}

	/** Keys land roughly evenly, or one node carries the cluster. **/
	public function testKeysAreSpreadAcrossTheMembership():Void {
		var nodes = ["a", "b", "c", "d", "e", "f", "g", "h"];
		var hash = ring(nodes);
		var counts = new Map<String, Int>();
		var total:Int = 8000;

		for (i in 0...total) {
			var owner = hash.owner("key-" + i);
			counts.set(owner, (counts.exists(owner) ? counts.get(owner) : 0) + 1);
		}

		var fair:Float = total / nodes.length;

		for (node in nodes) {
			var got:Int = counts.exists(node) ? counts.get(node) : 0;
			Assert.isTrue(got > fair * 0.6 && got < fair * 1.4,
				node + " took " + got + " of " + total + " keys against a fair share of " + fair);
		}
	}

	/**
		Removing a node moves its keys and nobody else's.

		This is the whole reason for the scheme. A key that moves is state
		that has to be rebuilt somewhere, so a membership change that
		reshuffled keys between nodes that are both still up would cost far
		more than the one that left.
	**/
	public function testRemovingANodeMovesOnlyItsOwnKeys():Void {
		var nodes = ["a", "b", "c", "d", "e"];
		var before = ring(nodes);
		var owners = new Map<String, String>();
		var total:Int = 4000;

		for (i in 0...total) {
			owners.set("key-" + i, before.owner("key-" + i));
		}

		var after = ring(nodes);
		after.remove("c");

		var movedFromC:Int = 0;
		var movedFromOthers:Int = 0;

		for (i in 0...total) {
			var key = "key-" + i;
			var was = owners.get(key);
			var now = after.owner(key);

			if (was == now) {
				continue;
			}

			if (was == "c") {
				movedFromC++;
			} else {
				movedFromOthers++;
			}
		}

		Assert.equals(0, movedFromOthers, movedFromOthers + " keys moved between nodes that were both still up");
		Assert.isTrue(movedFromC > 0, "removing a node moved none of its keys");
	}

	/** Adding a node takes a share and disturbs nothing else. **/
	public function testAddingANodeOnlyTakesAShare():Void {
		var before = ring(["a", "b", "c", "d"]);
		var owners = new Map<String, String>();
		var total:Int = 4000;

		for (i in 0...total) {
			owners.set("key-" + i, before.owner("key-" + i));
		}

		var after = ring(["a", "b", "c", "d"]);
		after.add("e");

		var moved:Int = 0;
		var movedElsewhere:Int = 0;

		for (i in 0...total) {
			var key = "key-" + i;

			if (owners.get(key) == after.owner(key)) {
				continue;
			}

			moved++;

			if (after.owner(key) != "e") {
				movedElsewhere++;
			}
		}

		Assert.equals(0, movedElsewhere, movedElsewhere + " keys moved somewhere other than the node that joined");
		Assert.isTrue(moved > 0, "a new node took nothing");
		Assert.isTrue(moved < total / 2, "a new node took " + moved + " of " + total + ", far past its share");
	}

	/** Replicas are ranked, distinct, and agreed on by everyone. **/
	public function testOwnersRanksDistinctNodesInAnAgreedOrder():Void {
		var one = ring(["a", "b", "c", "d"]);
		var two = ring(["c", "a", "d", "b"]);

		// Reported once rather than per key, so two hundred passes do not
		// print a thousand dots.
		var wrong:String = null;

		for (i in 0...200) {
			var key = "room-" + i;
			var first = one.owners(key, 3);
			var second = two.owners(key, 3);
			var seen = new Map<String, Bool>();
			var repeated:Bool = false;

			for (node in first) {
				if (seen.exists(node)) {
					repeated = true;
				}

				seen.set(node, true);
			}

			if (first.length != 3) {
				wrong = key + " ranked " + first.length + " nodes rather than three";
			} else if (first.join(",") != second.join(",")) {
				wrong = "two nodes ranked " + key + " differently: " + first.join(",") + " against " + second.join(",");
			} else if (first[0] != one.owner(key)) {
				wrong = "the best of owners() is not owner() for " + key;
			} else if (repeated) {
				wrong = "a node appeared twice in the ranking for " + key;
			}

			if (wrong != null) {
				break;
			}
		}

		Assert.isNull(wrong, wrong);
	}

	/**
		The arithmetic is pinned, because two targets must not disagree.

		Every other case here checks that one target agrees with itself. The
		thing that actually matters is that a jvm node and a native node
		reach the same owner for the same key, and no test comparing a target
		to itself can see a divergence between them. These are the values the
		algorithm produces; a target that differs fails here rather than by
		quietly serving the same room from two places.
	**/
	public function testTheOwnerOfAKeyIsTheSameOnEveryTarget():Void {
		var hash = ring(["alpha", "beta", "gamma", "delta", "epsilon"]);

		Assert.equals("beta", hash.owner("room:1"));
		Assert.equals("beta", hash.owner("room:2"));
		Assert.equals("beta", hash.owner("player:abc"));
		Assert.equals("epsilon", hash.owner("shard/7"));
		Assert.equals("gamma", hash.owner(""));
	}

	/** An empty membership owns nothing, rather than guessing. **/
	public function testAnEmptyMembershipOwnsNothing():Void {
		var hash = new Rendezvous();

		Assert.isNull(hash.owner("anything"));
		Assert.equals(0, hash.owners("anything", 3).length);

		hash.add("a");
		Assert.equals("a", hash.owner("anything"));
		Assert.isFalse(hash.add("a"), "adding a node twice reported it as new");
		Assert.equals(1, hash.length);
	}

	static function ring(nodes:Array<String>):Rendezvous {
		var out = new Rendezvous();

		for (node in nodes) {
			out.add(node);
		}

		return out;
	}
}
