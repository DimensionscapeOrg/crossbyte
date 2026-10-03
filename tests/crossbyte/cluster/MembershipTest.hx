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

	/**
		`now` left out, or negative, asks the membership's clock. It was a
		`?now:Float`: a `Null<Float>`, which a native build makes an object
		of on every heartbeat that passes one.
	**/
	public function testANegativeNowAsksTheClock():Void {
		var now:Float = 100;
		var alive = new Membership(5, 1024, function():Float return now);

		alive.heard("a", -1);
		Assert.equals(100.0, alive.lastHeardFrom("a"), "a negative time was taken as the time");
		alive.heard("b", 99);
		Assert.equals(99.0, alive.lastHeardFrom("b"));

		now = 103;
		Assert.equals(0, alive.sweep(-1));
		now = 104;
		Assert.equals(1, alive.sweep(-1), "the sweep did not ask the clock");
		Assert.isTrue(alive.has("a"));
		Assert.isFalse(alive.has("b"));
	}

	/**
		A node that leaves is reported once, and counted once, when what is
		told of another leaving forgets it first. The sweep found both and
		then dropped each: the second a second time, reported again, and
		counted off `length` again.
	**/
	public function testALeaveThatForgetsAnotherIsReportedOnce():Void {
		var now:Float = 0;
		var alive = new Membership(5, 1024, function():Float return now);
		var left:Array<String> = [];
		alive.onLeave = function(node:String):Void {
			left.push(node);
			// "a" and "b" are a pair: one gone takes the other with it.
			if (node == "a") {
				alive.forget("b");
			} else if (node == "b") {
				alive.forget("a");
			}
		};
		alive.heard("a");
		alive.heard("b");
		alive.heard("c");

		now = 10;
		alive.sweep();
		left.sort(Reflect.compare);
		Assert.equals("a,b,c", left.join(","), "left: " + left.join(","));
		Assert.equals(0, alive.length);
		Assert.equals(0, alive.alive().length);

		// And what remains still works.
		Assert.isTrue(alive.heard("d"));
		Assert.equals(1, alive.length);
	}

	/** Many nodes, some leaving, the rest kept, each where it was. **/
	public function testASweepOfManyKeepsTheRest():Void {
		var now:Float = 0;
		var alive = new Membership(5, 0, function():Float return now);
		for (i in 0...100) {
			alive.heard("n" + i);
		}
		now = 4;
		for (i in 0...100) {
			if (i % 3 == 0) {
				alive.heard("n" + i);
			}
		}
		now = 6;
		Assert.equals(66, alive.sweep());
		Assert.equals(34, alive.length);
		for (i in 0...100) {
			Assert.equals(i % 3 == 0, alive.has("n" + i));
			if (i % 3 == 0) {
				Assert.equals(4.0, alive.lastHeardFrom("n" + i));
			}
		}
		var names = alive.alive();
		Assert.equals(34, names.length);
		alive.clear();
		Assert.equals(0, alive.length);
		Assert.isFalse(alive.has("n0"));
		Assert.isTrue(alive.heard("n0"));
	}

	/** A membership with no timeout is a mistake, not a configuration. **/
	public function testATimeoutIsRequired():Void {
		Assert.raises(function():Void {
			new Membership(0);
		}, ArgumentError);
	}
}
