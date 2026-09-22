package crossbyte.cluster;

import crossbyte.errors.ArgumentError;
import utest.Assert;

/** Who is alive, from how recently each node was heard from. **/
class MembershipTest extends utest.Test {
	/** Joining and leaving are reported once each, not on every heartbeat. **/
	public function testJoinAndLeaveAreReportedOnce():Void {
		var now:Float = 0;
		var alive = new Membership(5, 1024, function():Float return now);
		var joined:Array<String> = [];
		var left:Array<String> = [];
		alive.onJoin = node -> joined.push(node);
		alive.onLeave = node -> left.push(node);

		alive.heard("a");
		now = 1;
		alive.heard("a");
		now = 2;
		alive.heard("a");

		Assert.equals("a", joined.join(","), "a node joined more than once while heartbeating");
		Assert.equals(1, alive.length);

		now = 8;
		Assert.equals(1, alive.sweep());
		Assert.equals("a", left.join(","));
		Assert.equals(0, alive.length);

		// And sweeping again reports nothing, rather than leaving twice.
		now = 20;
		Assert.equals(0, alive.sweep());
		Assert.equals("a", left.join(","), "a node left twice");
	}

	/** A node that keeps heartbeating is not swept. **/
	public function testANodeThatKeepsTalkingStays():Void {
		var now:Float = 0;
		var alive = new Membership(5, 1024, function():Float return now);

		alive.heard("a");
		alive.heard("b");

		for (i in 1...20) {
			now = i * 2;
			alive.heard("a");
			alive.sweep();
		}

		Assert.isTrue(alive.has("a"), "a node heartbeating every two seconds was dropped on a five second timeout");
		Assert.isFalse(alive.has("b"), "a node that went quiet was kept");
		Assert.equals(1, alive.length);
	}

	/**
		A name arrives from outside, so the set of them is bounded.

		Nothing here can tell a real node from an invented one, and a peer
		that makes them up would otherwise grow the membership for as long as
		it cared to.
	**/
	public function testTheNumberOfNodesIsBounded():Void {
		var now:Float = 0;
		var alive = new Membership(60, 8, function():Float return now);

		for (i in 0...400) {
			alive.heard("node-" + i);
		}

		Assert.equals(8, alive.length, "the membership held " + alive.length + " against a bound of 8");

		// And one already known is still accepted at the bound.
		Assert.isFalse(alive.heard("node-0"), "a known node reported as newly joined");
		Assert.isTrue(alive.has("node-0"), "a known node was refused at the bound");
	}

	/** How long a node has been quiet is readable before it times out. **/
	public function testHowLongANodeHasBeenQuietIsReadable():Void {
		var now:Float = 100;
		var alive = new Membership(30, 1024, function():Float return now);

		alive.heard("a");
		now = 118;

		Assert.equals(100.0, alive.lastHeardFrom("a"));
		Assert.equals(-1.0, alive.lastHeardFrom("never-seen"));
		Assert.isTrue(alive.has("a"), "a node was dropped before its timeout");
	}

	/** Dropping a node explicitly reports it as leaving. **/
	public function testForgettingANodeReportsItLeaving():Void {
		var alive = new Membership(30, 1024, function():Float return 0);
		var left:Array<String> = [];
		alive.onLeave = node -> left.push(node);

		alive.heard("a");
		Assert.isTrue(alive.forget("a"));
		Assert.equals("a", left.join(","));
		Assert.isFalse(alive.forget("a"), "forgetting an unknown node reported success");
	}

	/** A membership with no timeout is a mistake, not a configuration. **/
	public function testATimeoutIsRequired():Void {
		Assert.raises(function():Void {
			new Membership(0);
		}, ArgumentError);
	}
}
