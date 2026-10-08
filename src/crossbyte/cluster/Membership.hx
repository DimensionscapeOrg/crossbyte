package crossbyte.cluster;

import crossbyte.errors.ArgumentError;
import haxe.ds.StringMap;

/**
	Which nodes are alive, from how recently each was heard from.

	Knows nothing about how a heartbeat arrives (a datagram, a `NetHost`
	broadcast, a row in a table someone else writes). Tell it what was heard
	and when, sweep it on the tick, and it says who is there and reports the
	changes. That is deliberately all it does: who should be sent what is a
	policy written against this, and `Rendezvous` is where it usually goes.

	```haxe
	var alive = new Membership(5.0);
	alive.onJoin = node -> ring.add(node);
	alive.onLeave = node -> ring.remove(node);

	alive.heard(nodeName);   // whenever a heartbeat arrives
	alive.sweep();           // from the tick
	```

	## On the timeout

	A node declared gone that was only slow is expensive: its keys move,
	whatever held them is rebuilt elsewhere, and it all moves back when the
	node reappears. Set the timeout at several times the heartbeat interval
	rather than close to it.

	This decides on one number, which is the simple thing rather than the
	clever one. An implementation that watched how regular a node's
	heartbeats had been could suspect a node that went quiet early and give a
	reliably-jittery one more room, and `lastHeardFrom` is exposed so that
	can be built on top without this having an opinion about it.

	A timeout of 0 is none, as everywhere in CrossByte: no node is ever
	declared gone for being quiet, and one leaves only by `forget`.
**/
class Membership {
	/**
		The longest a name may be: 255 characters. A longer one is refused,
		as a name past `maxNodes` is.

		`maxNodes` bounds how many names are held and this how long each
		is, so a peer cannot make each of its 1,024 a megabyte.
	**/
	public static inline var MAX_NAME_LENGTH:Int = 255;

	/**
		Seconds a node may go unheard before it is considered gone, or 0 for
		no limit: a node then stays until it is forgotten.
	**/
	public var timeout(default, null):Float;

	/**
		The most nodes tracked at once: 1,024 unless the constructor was given
		another, and 0 for no limit.

		A name arrives from outside and nothing here can tell a real node
		from an invented one, so a peer that makes them up would otherwise
		grow this without limit. Past the bound a name that is not already
		known is refused rather than admitted. Each name held costs its
		characters (at most `MAX_NAME_LENGTH`) and a small record.
	**/
	public var maxNodes(default, null):Int;

	/** How many nodes are currently alive. **/
	public var length(default, null):Int = 0;

	/** Called when a node is heard from that was not alive a moment ago. **/
	public dynamic function onJoin(node:String):Void {}

	/** Called when a node has gone unheard for longer than `timeout`. **/
	public dynamic function onLeave(node:String):Void {}

	// Each node once, in a list the sweep walks by index and a map from its
	// name: the sweep asks no map anything, and makes nothing while no one
	// leaves.
	private var __heard:StringMap<HeardNode>;
	private var __order:Array<HeardNode> = [];
	// No node was last heard from before this: the sweep looks at none of
	// them until it is `timeout` old, which with heartbeats coming is once a
	// timeout rather than every tick. Exact after a sweep that looked, and
	// only ever earlier than the truth between them.
	private var __earliest:Float = Math.POSITIVE_INFINITY;
	private var __clock:Void->Float;

	/**
		@param timeout Seconds a node may go unheard before it is gone, or 0
		       for no limit.
		@param maxNodes The most to track; zero for no limit, which is only
		       safe when the names come from somewhere trusted.
		@param clock Where the time comes from. Supply one in a test.
		@throws ArgumentError For a negative or NaN `timeout`, and a negative
		        `maxNodes`.
	**/
	public function new(timeout:Float, maxNodes:Int = 1024, ?clock:Void->Float) {
		if (Math.isNaN(timeout) || timeout < 0) {
			throw new ArgumentError('A membership timeout is a number of seconds, 0 for none: $timeout is not one.');
		}

		if (maxNodes < 0) {
			throw new ArgumentError('A membership maxNodes must not be negative ($maxNodes); 0 is no limit.');
		}

		this.timeout = timeout;
		this.maxNodes = maxNodes;
		this.__clock = clock == null ? function():Float return haxe.Timer.stamp() : clock;
		this.__heard = new StringMap();
	}

	/**
		Records that a node was heard from.

		@param now When, by the clock this was made with; left out, or
		       negative, it asks that clock.
		@return Whether this is the first time it has been heard from since
		        @return Whether this is the first time it has been heard from since
		                it was last alive, which is when `onJoin` fires. Returns
		                false for a name refused by `maxNodes` or longer than
		                `MAX_NAME_LENGTH`.
		@throws ArgumentError For a null or empty name, and a `now` of NaN.
	**/
	public function heard(node:String, now:Float = -1):Bool {
		if (node == null || node == "") {
			throw new ArgumentError("A node needs a name.");
		}

		var at:Float = __when(now);
		var entry:HeardNode = __heard.get(node);

		if (entry != null) {
			entry.at = at;
			if (at < __earliest) {
				__earliest = at;
			}
			return false;
		}

		if ((maxNodes > 0 && length >= maxNodes) || node.length > MAX_NAME_LENGTH) {
			return false;
		}

		entry = new HeardNode(node, at, __order.length);
		if (at < __earliest) {
			__earliest = at;
		}
		__heard.set(node, entry);
		__order.push(entry);
		length++;
		onJoin(node);
		return true;
	}

	/**
		Drops whatever has gone unheard for longer than `timeout`.

		@param now When, by the clock this was made with; left out, or
		       negative, it asks that clock.
		@return How many left: always 0 with a `timeout` of 0.
		@throws ArgumentError For a `now` of NaN.
	**/
	public function sweep(now:Float = -1):Int {
		var at:Float = __when(now);
		if (timeout == 0 || at - __earliest < timeout) {
			return 0;
		}

		var gone:Array<HeardNode> = null;
		var earliest:Float = Math.POSITIVE_INFINITY;

		for (i in 0...__order.length) {
			var entry:HeardNode = __order[i];
			if (at - entry.at >= timeout) {
				if (gone == null) {
					gone = [];
				}

				gone.push(entry);
			} else if (entry.at < earliest) {
				earliest = entry.at;
			}
		}
		// Before anyone is told: what they are told may hear from a node.
		__earliest = earliest;

		if (gone == null) {
			return 0;
		}

		// Reported after all are found, as each `onLeave` may change the
		// membership; one an earlier `onLeave` forgot is not reported twice.
		var left:Int = 0;
		for (entry in gone) {
			if (__drop(entry)) {
				left++;
				onLeave(entry.name);
			}
		}

		return left;
	}

	/** Whether a node is currently alive. **/
	public function has(node:String):Bool {
		return __heard.exists(node);
	}

	/**
		When a node was last heard from, or -1 for one that is not alive.

		For anything wanting to decide about a node before `timeout` does:
		how long it has been quiet is the measurement that decision is made
		from.
	**/
	public function lastHeardFrom(node:String):Float {
		var entry:HeardNode = __heard.get(node);
		return entry != null ? entry.at : -1;
	}

	/** Everyone currently alive, in no particular order. **/
	public function alive():Array<String> {
		return [for (entry in __order) entry.name];
	}

	/** Drops a node now, without waiting for it to time out. **/
	public function forget(node:String):Bool {
		var entry:HeardNode = __heard.get(node);
		if (entry == null || !__drop(entry)) {
			return false;
		}

		onLeave(node);
		return true;
	}

	/** Drops everyone, without reporting any of them as leaving. **/
	public function clear():Void {
		for (entry in __order) {
			entry.slot = -1;
		}
		__heard = new StringMap();
		__order = [];
		__earliest = Math.POSITIVE_INFINITY;
		length = 0;
	}

	/** `now`, or the clock's time for a negative one; NaN is refused. **/
	private inline function __when(now:Float):Float {
		if (Math.isNaN(now)) {
			throw new ArgumentError("A membership was given a time of NaN.");
		}

		return now < 0 ? __clock() : now;
	}

	/**
		Takes a node out, its place in the list filled by the last: false
		for one already out.
	**/
	private function __drop(entry:HeardNode):Bool {
		var slot:Int = entry.slot;
		if (slot < 0 || slot >= __order.length || __order[slot] != entry) {
			return false;
		}

		var last:HeardNode = __order.pop();
		if (last != entry) {
			__order[slot] = last;
			last.slot = slot;
		}
		entry.slot = -1;
		__heard.remove(entry.name);
		length--;
		return true;
	}
}

/** A node alive, when it was last heard from, and where it is in the list. **/
private class HeardNode {
	public var name:String;
	public var at:Float;
	public var slot:Int;

	public function new(name:String, at:Float, slot:Int) {
		this.name = name;
		this.at = at;
		this.slot = slot;
	}
}
